#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXPORTER="$ROOT_DIR/tools/zmk-layout-rs/profiles/keyboards/go60/export-editor-json.sh"
OUTPUT="$ROOT_DIR/go60-editor.json"

if [[ ! -f "$EXPORTER" ]]; then
  printf 'Editor exporter is unavailable. Initialize the submodule with:\n' >&2
  printf '  git -C "%s" submodule update --init --recursive -- tools/zmk-layout-rs\n' "$ROOT_DIR" >&2
  exit 1
fi

for dependency in jq trash; do
  if ! command -v "$dependency" >/dev/null; then
    printf 'required command not found: %s\n' "$dependency" >&2
    exit 1
  fi
done

temporary_dir="$(mktemp -d)"
trap 'trash "$temporary_dir"' EXIT

bash "$EXPORTER" "$ROOT_DIR/config/go60.keymap" "$temporary_dir/generated.json"

if [[ -f "$OUTPUT" ]]; then
  jq --slurpfile previous "$OUTPUT" '
    .uuid = ($previous[0].uuid // .uuid)
    | .date = ($previous[0].date // .date)
  ' "$temporary_dir/generated.json" > "$temporary_dir/editor.json"
else
  mv "$temporary_dir/generated.json" "$temporary_dir/editor.json"
fi

mv "$temporary_dir/editor.json" "$OUTPUT"
printf 'Updated editor export: %s\n' "$OUTPUT"
