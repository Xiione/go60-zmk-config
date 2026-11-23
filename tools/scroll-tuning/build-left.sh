#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
image=go60-zmk-config-docker:latest
source "$root/firmware.env"
revision=$FIRMWARE_REVISION
script=/config/tools/scroll-tuning/build-left.sh

if [[ ${1:-} == --inside ]]; then
    shift
    cache=/scroll-tuning
    mkdir -p "$cache"
    flock="$cache/lock-tools-bin/bin/flock"
    if [[ ! -x "$flock" ]]; then
        nix-build -E '(import /src/nix/pinned-nixpkgs.nix {}).util-linux' -o "$cache/lock-tools"
    fi
    lock_status=0
    "$flock" -n -E 75 "$cache/build.lock" \
        bash "$script" --locked "$@" || lock_status=$?
    if [[ $lock_status == 75 ]]; then
        printf '%s\n' "A tuning build is already running." >&2
    fi
    exit "$lock_status"
fi

if [[ ${1:-} == --locked ]]; then
    shift
    mode=$1
    shift
    cache=/scroll-tuning
    mkdir -p "$cache"
    bash /config/tools/firmware/checkout.sh
    if [[ ! -x "$cache/ccache/bin/ccache" ]]; then
        nix-build -E '(import /src/nix/pinned-nixpkgs.nix {}).ccache' -o "$cache/ccache"
    fi

    # nix-shell supplies the same compiler, libraries and board flags as the release derivation.
    export GO60_TUNING_MODE="$mode"
    export GO60_TUNING_SETTINGS
    GO60_TUNING_SETTINGS=$(printf '%s\n' "$@")
    exec nix-shell /config/config --arg leftOnly true --arg firmware 'import /src/default.nix {}' \
        --run "bash $script --compile"
fi

if [[ ${1:-} == --compile ]]; then
    cache=/scroll-tuning
    cd /config
    # Only toolchain, source, module and Kconfig changes select a fresh tree.
    fingerprint=$(
        printf '%s\n' "$revision" "$GO60_TUNING_MODE" "$cmakeFlags"
        sha256sum config/go60_lh.conf \
            tools/scroll-tuning/build-left.sh tools/scroll-tuning/prepare.py tools/scroll-tuning/trace.h
        find modules/zmk-{raw-hid,hid-viz,input-processor-scroll-inertia} \
            -type f ! -name .git -print0 |
            sort -z | xargs -0 sha256sum
    )
    # The Nix keymap and conf paths incorporate the config directory hash.
    key=$(printf '%s\n' "$fingerprint" | sed -E 's@(-D(KEYMAP_FILE|EXTRA_CONF_FILE)=)[^ ]+@\1@' |
        sha256sum | cut -c1-24)
    work="$cache/$key"
    mkdir -p "$work/config"
    if [[ ! -f "$work/ready" ]]; then
        mkdir -p "$work/source"
        git -C /src archive "$revision" | tar -x -C "$work/source"
        python /config/tools/scroll-tuning/prepare.py prepare "$work" "$GO60_TUNING_MODE"
        touch "$work/ready"
    fi

    python /config/tools/scroll-tuning/prepare.py keymap "$work"
    read -r -a nix_flags <<< "$cmakeFlags"
    flags=()
    for flag in "${nix_flags[@]}"; do
        case "$flag" in
            -DKEYMAP_FILE=*|-DEXTRA_CONF_FILE=*|-DZMK_EXTRA_MODULES=*) ;;
            *) flags+=("$flag") ;;
        esac
    done
    export CCACHE_DIR="$cache/compiler-cache"
    export CCACHE_MAXSIZE=1G
    ccache="$cache/ccache/bin/ccache"
    cd "$work/source/app"
    build="$work/build"
    inputs=$(sha256sum "$work/config/go60.keymap" "$work/config/go60_lh.keymap")
    if [[ ! -f "$build/build.ninja" || ! -f "$work/inputs" || $(cat "$work/inputs") != "$inputs" ]]; then
        cmake -S . -B "$build" -G Ninja "${flags[@]}" \
            "-DUSER_CACHE_DIR=$cache/zephyr-cache" \
            "-DCMAKE_C_COMPILER_LAUNCHER=$ccache" \
            "-DCMAKE_CXX_COMPILER_LAUNCHER=$ccache" \
            "-DKEYMAP_FILE=$work/config/go60_lh.keymap" \
            "-DEXTRA_CONF_FILE=$work/config/go60_lh.conf" \
            "-DZMK_EXTRA_MODULES=/config/modules/zmk-raw-hid;/config/modules/zmk-hid-viz;$work/inertia"
        printf '%s\n' "$inputs" > "$work/inputs"
    fi
    cmake --build "$build" --parallel "${ZMK_BUILD_JOBS:-4}"
    "$ccache" --show-stats
    case "$GO60_TUNING_MODE" in
        trace) artifact=go60-lh-scroll-trace.uf2 ;;
        release) artifact=go60-lh-scroll-tuned.uf2 ;;
    esac
    config="$build/zephyr/.config"
    grep -qx CONFIG_ZMK_POINTING_SCROLL_RESOLUTION=100 "$config"
    grep -qx CONFIG_ZMK_INPUT_PROCESSOR_SCROLL_INERTIA=y "$config"
    if [[ $GO60_TUNING_MODE == trace ]]; then
        grep -qx CONFIG_USB_CDC_ACM=y "$config"
    fi
    install -m 644 "$build/zephyr/zmk.uf2" "/config/$artifact"
    python /config/tools/firmware/manifest.py "tuning-$GO60_TUNING_MODE" "$build/zephyr" "/config/$artifact" /src
    printf '%s\n' "Built $artifact"
    exit 0
fi

usage() {
    printf '%s\n' "Usage: $0 [--release] [--set NAME=VALUE ...] | --stop-container | --reset-container"
}

container="go60-scroll-tuning-$(printf '%s' "$root" | shasum | cut -c1-12)"
mode=trace
settings=()
while (($#)); do
    case "$1" in
        --release) mode=release; shift ;;
        --set)
            (($# >= 2)) || { usage >&2; exit 2; }
            settings+=("$2"); shift 2 ;;
        --stop-container) docker stop "$container"; exit ;;
        --reset-container) docker rm -f "$container"; exit ;;
        -h|--help) usage; exit ;;
        *) usage >&2; exit 2 ;;
    esac
done

if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker build -t "$image" "$root"
fi
if ! docker container inspect "$container" >/dev/null 2>&1; then
    docker run -d --name "$container" -v "$root:/config" --entrypoint sleep "$image" infinity >/dev/null
elif [[ $(docker inspect -f '{{.State.Running}}' "$container") != true ]]; then
    docker start "$container" >/dev/null
fi
# Bash 3.2 with nounset needs a special expansion for empty arrays.
time docker exec -e "ZMK_BUILD_JOBS=${ZMK_BUILD_JOBS:-4}" "$container" \
    bash "$script" --inside "$mode" ${settings[@]+"${settings[@]}"}
