#!/bin/zsh
# Builds the Media Shuttle promo video for the website, following the devrel-video skill
# (github.com/aaitor/skill-video-studio): capture → compose (HyperFrames) → render + QA → thumbnail.
#
#   ./docs/video/build.sh
#
# Needs Xcode/Swift, FFmpeg, Node (for `npx hyperframes`) and Chrome for the thumbnail (the one HyperFrames downloads works).
# Writes site/assets/promo.{mp4,webm}, promo-poster.jpg, promo-thumbnail.jpg and docs/video/build/renders/*.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/build"
SITE="$ROOT/site/assets"
export HYPERFRAMES_NO_TELEMETRY=1 DO_NOT_TRACK=1 HYPERFRAMES_SKIP_SKILLS=1
HF=(npx --yes hyperframes@0.9.19)

rm -rf "$BUILD"
mkdir -p "$BUILD/frames" "$BUILD/renders"

print "== capture: render the real app window through a scripted ingest =="
swift build --package-path "$ROOT/macos" --scratch-path "$BUILD/swift" >/dev/null
"$BUILD/swift/debug/MediaShuttle" --screenshot --render-demo-frames "$BUILD/frames"
ffmpeg -v error -y -f concat -safe 0 -i "$BUILD/frames/frames.txt" \
    -vf "scale=1920:1080:flags=lanczos,fps=30,format=yuv420p" \
    -c:v libx264 -crf 14 -preset slow -movflags +faststart "$BUILD/capture.mp4"
ffprobe -v error -show_entries format=duration -of csv=p=0 "$BUILD/capture.mp4"


print "== compose =="
cp "$HERE/index.html" "$HERE/thumbnail.html" "$BUILD/"
cp "$ROOT/site/assets/icon.png" "$BUILD/icon.png"
curl -fsSL -o "$BUILD/gsap.min.js" https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js

print "== lint + check + render =="
cd "$BUILD"
"${HF[@]}" lint
"${HF[@]}" check
"${HF[@]}" render --quality high -o renders/out.mp4

print "== web copies =="
ffmpeg -v error -y -i renders/out.mp4 -c:v libx264 -crf 23 -preset slow -pix_fmt yuv420p \
    -vf "scale=1600:-2:flags=lanczos" -movflags +faststart -an "$SITE/promo.mp4"
ffmpeg -v error -y -i renders/out.mp4 -c:v libvpx-vp9 -b:v 0 -crf 36 -row-mt 1 \
    -vf "scale=1600:-2:flags=lanczos" -an "$SITE/promo.webm"
# The poster is the verified state, so the page reads correctly before the video plays.
ffmpeg -v error -y -ss 13.2 -i renders/out.mp4 -frames:v 1 -vf "scale=1600:-2" -q:v 3 "$SITE/promo-poster.jpg"

print "== QA =="
ffprobe -v error -show_entries format=duration,size \
    -show_entries stream=codec_name,width,height,r_frame_rate -of default renders/out.mp4
ffmpeg -v error -y -i renders/out.mp4 -vf "fps=1/2,scale=480:-1,tile=4x3" -frames:v 1 renders/contact.png

print "== thumbnail =="
# Google Chrome if installed, else the headless shell HyperFrames downloaded for the render above.
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ ! -x "$CHROME" ]]; then
    CHROME="$(find "$HOME/.cache" -type f -name chrome-headless-shell -perm -u+x 2>/dev/null | sort | tail -1)"
fi
[[ -x "$CHROME" ]] || { print -u2 "No Chrome found for the thumbnail."; exit 1; }
ffmpeg -v error -y -ss 10.0 -i capture.mp4 -frames:v 1 renders/hero.png
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --window-size=1280,720 --virtual-time-budget=4000 \
    --screenshot="$BUILD/renders/thumbnail.png" "file://$BUILD/thumbnail.html" >/dev/null 2>&1
ffmpeg -v error -y -i renders/thumbnail.png -q:v 3 renders/thumbnail.jpg
cp renders/thumbnail.jpg "$SITE/promo-thumbnail.jpg"

print "wrote $SITE/promo.mp4 ($(du -h "$SITE/promo.mp4" | cut -f1)), promo.webm ($(du -h "$SITE/promo.webm" | cut -f1)), promo-poster.jpg"
print "REVIEW renders/contact.png and renders/thumbnail.jpg: no clipped text, correct product state, no PII."
