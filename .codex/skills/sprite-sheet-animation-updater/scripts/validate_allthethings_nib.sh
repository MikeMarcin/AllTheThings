#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$(pwd)}"
skill_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${repo_root}"

python3 "${skill_root}/scripts/validate_sprite_sheet.py" \
  --sheet Resources/NibGeneratedMasterSheet.png \
  --cell-width 160 \
  --cell-height 96 \
  --columns 10 \
  --rows 7 \
  --animations idle:8,indexing:10,searching:10,optimizing:10,file_changed:6,success:8,error:6 \
  --body-color mascot-blue \
  --min-gutter 1 \
  --body-width-range 69:78 \
  --body-height-range 78:90 \
  --body-center-range 79:84 \
  --max-center-drift 3 \
  --preview /tmp/allthethings-nib-sprite-sheet-preview.png

swift test
cmake --build build/cmake
