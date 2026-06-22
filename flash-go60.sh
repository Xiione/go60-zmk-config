#!/usr/bin/env bash

set -euo pipefail

usage() {
  printf 'Usage: %s path/to/go60.uf2\n' "$(basename "$0")" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

firmware=$1

if [[ ! -f "$firmware" ]]; then
  printf 'error: not a file: %s\n' "$firmware" >&2
  exit 2
fi

if [[ ${firmware##*.} != uf2 ]]; then
  printf 'error: expected a .uf2 file: %s\n' "$firmware" >&2
  exit 2
fi

add_volume() {
  local volume=$1
  local existing

  [[ -d "$volume" ]] || return 0

  for existing in "${volumes[@]}"; do
    [[ "$existing" == "$volume" ]] && return 0
  done

  volumes+=("$volume")
}

volume_still_mounted() {
  local volume=$1
  [[ -d "$volume" ]] && mount | grep -Fq " on $volume "
}

eject_volume() {
  local volume=$1

  volume_still_mounted "$volume" || return 0

  if command -v diskutil >/dev/null 2>&1; then
    diskutil quiet eject "$volume" >/dev/null 2>&1 && return 0
    volume_still_mounted "$volume" || return 0

    diskutil quiet unmount "$volume" >/dev/null 2>&1 && return 0
    volume_still_mounted "$volume" || return 0
  fi

  umount "$volume" >/dev/null 2>&1 || true
  volume_still_mounted "$volume" && return 1
  return 0
}

volumes=()
add_volume /Volumes/GO60LHBOOT
add_volume /Volumes/GO60RHBOOT

shopt -s nullglob
for volume in /Volumes/GO60*BOOT; do
  case "$(basename "$volume")" in
    GO60LHBOOT|GO60RHBOOT) add_volume "$volume" ;;
  esac
done
shopt -u nullglob

if [[ ${#volumes[@]} -eq 0 ]]; then
  printf 'error: no Go60 bootloader volumes found under /Volumes\n' >&2
  printf 'Put one or both halves in bootloader mode, then rerun this script.\n' >&2
  exit 1
fi

for volume in "${volumes[@]}"; do
  printf 'Flashing %s...\n' "$(basename "$volume")"

  # -X avoids writing extended attributes/resource forks to UF2 bootloaders.
  cp -X "$firmware" "$volume/"
  sync

  if eject_volume "$volume"; then
    printf 'Done: %s\n' "$(basename "$volume")"
  else
    printf 'warning: copied firmware, but could not eject %s cleanly\n' "$(basename "$volume")" >&2
    printf 'warning: macOS may still show a "disk not ejected properly" notification\n' >&2
  fi
done
