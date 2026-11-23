#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
image=go60-zmk-config-docker:latest
if [[ ${1:-} == --inside ]]; then
    bash /config/tools/firmware/checkout.sh
    result=$(nix-build /config/tools/pad-probe --arg firmware 'import /src/default.nix {}' --no-out-link -j2)
    install -m 644 "$result"/go60-*-pad-probe.uf2 /config/
    for side in lh rh; do
        bash /config/tools/firmware/manifest.sh probe "$result" "/config/go60-$side-pad-probe.uf2"
    done
    exit
fi
if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker build -t "$image" "$root"
fi
docker run --rm -v "$root:/config" --entrypoint bash "$image" /config/tools/pad-probe/build.sh --inside
