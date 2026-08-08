#!/bin/bash
# Builds the reel: narration via macOS `say`, scene cards rendered by
# render.swift, assembled with ffmpeg. Each scene is timed to its own
# narration rather than a fixed duration, so the pacing follows the voice.
set -euo pipefail
cd "$(dirname "$0")"

VOICE="${VOICE:-Samantha}"
RATE="${RATE:-178}"          # words per minute; reels want brisk
OUT=reel/WisprLocal-reel.mp4
mkdir -p reel/parts

NAMES=(01_hook 02_engine 03_demo 04_speed 05_private 06_cta)
LINES=(
"I cancelled my fifteen dollar a month dictation app, and rebuilt it in a weekend."
"Apple shipped a brand new speech engine in macOS twenty six. It runs entirely on your Mac."
"Hold right option. Speak. Release. The text lands wherever your cursor is, in any app."
"On the same audio, it's about ten times faster than Whisper."
"Airplane mode? Still works. No account, no subscription, and no audio ever leaves your Mac."
"It's free and open source. Comment GitHub, and I'll send you the link."
)

rm -f reel/parts/*.mp4 reel/parts/*.aiff reel/list.txt

for i in "${!NAMES[@]}"; do
    name=${NAMES[$i]}
    aiff=reel/parts/$name.aiff

    say -v "$VOICE" -r "$RATE" -o "$aiff" "${LINES[$i]}"
    speech=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$aiff")

    # A beat of air after each line so scenes don't collide, and a floor so a
    # short line still gets enough screen time to be read.
    dur=$(python3 -c "print(f'{max(float('$speech')+0.42, 2.4):.2f}')")
    frames=$(python3 -c "print(int(round(float('$dur')*30)))")

    # Slow push-in keeps a static card feeling alive; Instagram penalises
    # motionless video on retention.
    ffmpeg -y -v error \
        -loop 1 -i "reel/$name.png" -i "$aiff" \
        -filter_complex "\
[0:v]scale=2160:3840,zoompan=z='min(1.0+0.00035*on,1.06)':d=$frames:s=1080x1920:fps=30,\
format=yuv420p,fade=t=in:st=0:d=0.3,fade=t=out:st=$(python3 -c "print(f'{float('$dur')-0.3:.2f}')"):d=0.3[v];\
[1:a]adelay=250|250,apad,atrim=0:$dur,asetpts=N/SR/TB[a]" \
        -map "[v]" -map "[a]" -t "$dur" \
        -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 \
        -c:a aac -b:a 192k -ar 44100 -ac 2 \
        "reel/parts/$name.mp4"

    echo "file 'parts/$name.mp4'" >> reel/list.txt
    printf '  %-12s %5.2fs  %s\n' "$name" "$dur" "${LINES[$i]:0:52}..."
done

ffmpeg -y -v error -f concat -safe 0 -i reel/list.txt -c copy "$OUT"

echo
echo "built $OUT"
ffprobe -v error -show_entries format=duration:stream=width,height,codec_name \
        -of default=noprint_wrappers=1 "$OUT"
