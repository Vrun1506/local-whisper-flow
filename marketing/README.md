# Promo reel generation

Builds a 1080×1920 vertical reel from scratch — no editor, no stock assets.

```bash
cd marketing
swift render.swift .        # renders scene cards as PNGs
./assemble.sh               # narration + motion + encode → reel/*.mp4
```

`render.swift` draws the cards with AppKit because this Homebrew ffmpeg is built
without libfreetype, so `drawtext` isn't available. `assemble.sh` narrates each
line with macOS `say`, times each scene to its own narration, adds a slow
push-in, and concatenates.

Knobs: `VOICE=Daniel RATE=190 ./assemble.sh`

The narration is synthesized. Replace it with a real voiceover before posting —
a synthetic voice reads as low-effort on a personal "I built this" video, and
authenticity is most of the appeal.
