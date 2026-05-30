#!/bin/zsh
set -euo pipefail

usage() {
  echo "usage: render-computer-use-recording.sh <frames-dir> <fps> <output.gif|output.mp4>" >&2
  exit 2
}

redact_home() {
  local value=$1
  print -r -- "${value//$HOME/\$HOME}"
}

[[ $# -eq 3 ]] || usage

frames_dir=$1
fps=$2
output=$3

[[ -d "$frames_dir" ]] || {
  echo "frames directory not found: $(redact_home "$frames_dir")" >&2
  exit 1
}

[[ ! -e "$output" ]] || {
  echo "output already exists: $(redact_home "$output")" >&2
  exit 1
}

frames=("${(@f)$(find "$frames_dir" -maxdepth 1 -type f \( -name 'frame-*.jpg' -o -name 'frame-*.jpeg' -o -name 'frame-*.png' \) | sort)}")
[[ $#frames -gt 0 ]] || {
  echo "no frame images found in $(redact_home "$frames_dir")" >&2
  exit 1
}

canvas=$(magick identify -format '%w %h\n' "${frames[@]}" | awk '
  { if ($1 > w) w = $1; if ($2 > h) h = $2 }
  END { if (w < 1 || h < 1) exit 1; print w "x" h }
') || {
  echo "could not determine frame dimensions" >&2
  exit 1
}
canvas_filter=${canvas/x/:}

case "$output" in
  *.gif)
    delay=$(awk -v fps="$fps" 'BEGIN { if (fps <= 0) exit 1; d = int((100 / fps) + 0.5); if (d < 1) d = 1; print d }') || {
      echo "fps must be a positive number" >&2
      exit 1
    }
    magick -delay "$delay" -loop 0 "${frames[@]}" \
      -background black -gravity center -extent "$canvas" \
      "$output"
    ;;
  *.mp4)
    if ! command -v ffmpeg >/dev/null 2>&1; then
      echo "ffmpeg is required for MP4 output and is not installed" >&2
      exit 1
    fi
    ffmpeg -hide_banner -loglevel error \
      -framerate "$fps" \
      -pattern_type glob \
      -i "$frames_dir/frame-*.*" \
      -vf "scale=${canvas_filter}:force_original_aspect_ratio=decrease,pad=${canvas_filter}:(ow-iw)/2:(oh-ih)/2" \
      -pix_fmt yuv420p \
      "$output"
    ;;
  *)
    usage
    ;;
esac

echo "Wrote $(redact_home "$output") from $#frames frame(s)"
