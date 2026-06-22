#!/bin/bash

set -euo pipefail

IMAGE=go60-zmk-config-docker
ZMK_REPOSITORY="${ZMK_REPOSITORY:-moergo-sc/zmk}"
ZMK_REF="${1:-${ZMK_REF:-refs/pull/36/head}}"

docker build -t "$IMAGE" .
docker run --rm -v "$PWD:/config" -e UID="$(id -u)" -e GID="$(id -g)" -e ZMK_REPOSITORY="$ZMK_REPOSITORY" -e ZMK_REF="$ZMK_REF" "$IMAGE"
