#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
project_directory="$(cd "$script_directory/.." && pwd -P)"
helper="$script_directory/verify-public-tree.py"

usage() {
  cat >&2 <<'EOF'
Usage: Scripts/export-public-repo.sh [--dry-run] [--require-clean] <absolute-output-directory>

The command materializes a scanned candidate outside the canonical repository.
It never pushes, changes visibility, or overwrites a non-empty directory.
EOF
  exit 64
}

dry_run=0
require_clean=0
output_directory=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --require-clean)
      require_clean=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    -* )
      echo "unknown option" >&2
      usage
      ;;
    *)
      [[ -z "$output_directory" ]] || usage
      output_directory="$1"
      shift
      ;;
  esac
done

[[ -n "$output_directory" ]] || usage
[[ "$output_directory" == /* ]] || {
  echo "output directory must be an absolute path" >&2
  exit 64
}
[[ -f "$helper" && ! -L "$helper" ]] || {
  echo "public export helper is missing" >&2
  exit 1
}

# Resolve the candidate path without creating it first. The helper performs a
# second containment/symlink/non-empty check immediately before publishing the
# verified staging tree, closing the TOCTOU window for normal local use.
if [[ -e "$output_directory" && -L "$output_directory" ]]; then
  echo "output directory must not be a symlink" >&2
  exit 64
fi

args=(--export --repo "$project_directory" --output "$output_directory")
if [[ "$require_clean" -eq 1 ]]; then
  args+=(--require-clean)
fi

if [[ "$dry_run" -eq 1 ]]; then
  echo "PUBLIC_EXPORT_MODE: dry-run (candidate remains outside the repository)"
else
  echo "PUBLIC_EXPORT_MODE: materialize (no remote operation)"
fi

exec python3 "$helper" "${args[@]}"
