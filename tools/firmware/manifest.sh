#!/usr/bin/env bash
set -euo pipefail
python=$(nix-build -E '(import /src/nix/pinned-nixpkgs.nix {}).python3' --no-out-link)
"$python/bin/python3" /config/tools/firmware/manifest.py "$@" /src
