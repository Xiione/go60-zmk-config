#!/usr/bin/env bash
set -euo pipefail
source /config/firmware.env
repo=${ZMK_REPOSITORY:-$FIRMWARE_REPOSITORY}
ref=${ZMK_REF:-$FIRMWARE_REVISION}
cd /src
if [[ $ref == "$FIRMWARE_REVISION" ]] && git cat-file -e "$ref^{commit}" 2>/dev/null; then
    git checkout -q --detach "$ref"
else
    git fetch --no-tags "https://github.com/$repo.git" "$ref"
    git checkout -q --detach FETCH_HEAD
fi
