#!/bin/bash
# convert_videos.sh <game dir> : convert res/video/*.bik to H.264/AAC MP4 beside them (needs ffmpeg)
set -e
dir="$1/res/video"
[ -d "$dir" ] || { echo "no $dir"; exit 1; }
for f in "$dir"/*.bik "$dir"/*.BIK; do
  [ -e "$f" ] || continue
  out="${f%.*}.mp4"
  [ -s "$out" ] && continue
  ffmpeg -hide_banner -loglevel error -y -i "$f" -c:v h264_videotoolbox -b:v 6M -pix_fmt yuv420p -c:a aac -b:a 192k -movflags +faststart "$out"
  echo "converted $(basename "$f")"
done
