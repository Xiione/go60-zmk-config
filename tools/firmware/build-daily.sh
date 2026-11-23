#!/usr/bin/env bash
set -euo pipefail
bash /config/tools/firmware/checkout.sh
cd /config
result=$(nix-build ./config --arg firmware 'import /src/default.nix {}' -j2 --no-out-link)
install -m 644 "$result/go60.uf2" go60.uf2
bash tools/firmware/manifest.sh daily "$result" go60.uf2
