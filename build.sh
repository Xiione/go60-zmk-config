#!/bin/bash

set -euo pipefail

IMAGE=go60-zmk-config-docker
ZMK_REF=${1:-${ZMK_REF:-}}
export ZMK_REF

docker build -t "$IMAGE" .
docker run --rm -v "$PWD:/config" -e UID="$(id -u)" -e GID="$(id -g)" -e ZMK_REPOSITORY -e ZMK_REF="$ZMK_REF" "$IMAGE"

bash "$(dirname -- "${BASH_SOURCE[0]}")/export-editor-json.sh"
