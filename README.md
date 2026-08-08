# WisprLocal

Push-to-talk dictation for macOS. Hold **right ⌥**, speak, release — the text
lands wherever your cursor is. Runs entirely on your Mac, costs nothing, and
sends no audio anywhere. A free, local alternative to Wispr Flow.

![macOS](https://img.shields.io/badge/macOS-13%2B-black)
![Apple silicon + Intel](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-black)
![License](https://img.shields.io/badge/license-MIT-black)

## Requirements

| | Minimum | Notes |
|---|---|---|
| macOS | **13 Ventura** | Whisper engine works throughout |
| macOS | **26 Tahoe** | *additionally* unlocks the Apple engine (`SpeechAnalyzer`) |
| Architecture | Apple silicon or Intel | Homebrew prefix is detected automatically |
| Xcode | Command Line Tools | `xcode-select --install` |
| Disk | ~600 MB | only if you use the Whisper engine |

On macOS 13–15 the app runs Whisper only, and the engine picker hides the Apple
option rather than offering something that can't work. Apple's `SpeechAnalyzer`
framework is new in macOS 26 and has no back-deployment.

## Install

```bash
git clone https://github.com/Vrun1506/local-whisper-flow.git
cd local-whisper-flow
brew install whisper-cpp     # required on macOS < 26, optional above
./build.sh --run
```

That builds `~/Applications/WisprLocal.app` and launches it. A microphone icon
appears in the menu bar; there is no Dock icon by design.

Then grant the three permissions below — the app does nothing until you do.

## Permissions

Three grants, all to `~/Applications/WisprLocal.app` — note that is the
**`Applications` folder in your home directory**, not `/Applications`. In any
file picker, press **⌘⇧G** and type `~/Applications` to get there.

| Pane (System Settings › Privacy & Security) | Action | Without it |
|---|---|---|
| **Microphone** | Toggle WisprLocal on — usually auto-prompts | No audio is captured |
| **Input Monitoring** | Click **+**, add the app, toggle on | The hotkey silently never fires |
| **Accessibility** | Click **+**, add the app, toggle on | Text is transcribed but never pasted |

Two gotchas:

- **Input Monitoring only takes effect after a restart.** Grant it, quit from
  the menu bar, relaunch.
- The **+** panes rarely prompt on their own — expect to add the app by hand.

The menu bar's **Permissions** submenu shows a live ✅/❌ for each, so you never
have to guess which one is missing.

## Using it

Hold **right ⌥**, talk, let go. A HUD appears at the bottom of the screen with a
live waveform; with the Apple engine you also see the words as you say them.

The overlay wraps and grows upward as you talk, keeping its bottom edge fixed so
it doesn't shift under your gaze. It widens to half the screen (up to 760pt) and
grows to at most 8 lines; past that, the oldest words are dropped from the front
with a leading `…`, so the words you just said are always the ones on screen.

Check that behaviour without granting anything:

```bash
~/Applications/WisprLocal.app/Contents/MacOS/WisprLocal --demo-hud
```

Right ⌥ still types accented characters when combined with a letter — the app
observes the key rather than swallowing it. Holding it *alone* is the trigger,
and a bare modifier does nothing in macOS otherwise.

Taps shorter than 250 ms are ignored, so brushing the key won't fire anything.

## Menu

- **Engine** — switch between the two backends (see below)
- **Insert text by** — Paste (⌘V) or Type character-by-character
- **Remove filler words** — on by default; see below
- **Sound cues** — start/stop chirps
- **Permissions** — live status, click a row to open its pane
- **Recent dictations** — last 50, click to re-copy
- **Launch at login**

## Filler removal

On by default. Strips non-lexical noise before pasting:

```
"Hi, my name is Varun. Uh, I am using it, and this works."
                    → "Hi, my name is Varun. I am using it, and this works."
"Um, so I I think it works."   → "So I think it works."
```

It removes `um / uh / erm / er / mm / hmm / mhm / ah / eh` and immediate
stutters (`I I` → `I`), then repairs the leftover punctuation and capitalisation.

It is deliberately conservative, because deleting a word you meant is far worse
than leaving an "um" in. So it does **not** touch `like`, `you know`, `I mean`
or `sort of` — each is a real phrase often enough that stripping it would
corrupt sentences. It also leaves genuine doubles alone (`he had had enough`,
`the point that that makes`) and treats `No, no, I meant it` as emphasis rather
than a stutter.

Toggle it off in the menu for verbatim transcription. The test cases live in
`SelfTest.cleanerCases` and run on every `--selftest`.

## Engines

| | Apple Speech | Whisper large-v3-turbo |
|---|---|---|
| Setup | none — macOS downloads the model | 547 MB one-time download |
| Live preview | yes | no |
| Strength | everyday dictation | accents, noise, jargon |

Measured on an M2 against 11 seconds of speech:

| | Apple Speech | Whisper |
|---|---|---|
| Model load (once per launch) | 0.4s | 0.4s |
| Decode | **0.4s** | **4.2s** |

Apple's streams as you talk, so its transcript is essentially ready the instant
you release. Whisper only starts once you let go and runs at roughly 0.4×
realtime — a five-second dictation costs about two seconds of waiting. Worth it
when accuracy matters, which is why both are a menu click apart.

Both are fully offline. Apple's uses the `SpeechAnalyzer` framework new in
macOS 26; Whisper runs through Homebrew's `libwhisper` with Metal, linked
in-process so the model stays resident between utterances.

The Whisper model downloads to
`~/Library/Application Support/WisprLocal/` on first use of that engine.

## Verify it works

```bash
~/Applications/WisprLocal.app/Contents/MacOS/WisprLocal --selftest
```

Runs both engines against a known audio file and prints the transcripts and
timings. This exercises the real transcription path without needing any
permission or a working hotkey — the fastest way to tell an engine problem apart
from a permissions problem.

## Troubleshooting

**Hotkey does nothing.** Input Monitoring. Check the Permissions submenu; if it
shows ✅ but nothing happens, restart the app — the event tap is created at
launch.

**Transcribes but nothing is pasted.** Accessibility. Or the target app has
Secure Input on (password fields, some terminals) — the HUD says so explicitly,
and the text is on your clipboard and in Recent dictations either way.

**Permissions reset themselves after a rebuild.** This is already solved: the
build signs with a self-signed identity called `WisprLocal Dev`, which keeps the
code signature stable so grants survive rebuilds. Ad-hoc signatures (`-s -`)
bind grants to the binary's hash, which changes every single build.

If that identity is ever missing, `build.sh` silently falls back to ad-hoc and
the problem returns. Recreate it with:

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout wl.key -out wl.crt -subj "/CN=WisprLocal Dev" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
# -keypbe/-certpbe/-macalg are required: macOS can't read OpenSSL 3 defaults
openssl pkcs12 -export -inkey wl.key -in wl.crt -out wl.p12 -passout pass:wispr \
  -name "WisprLocal Dev" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import wl.p12 -k ~/Library/Keychains/login.keychain-db -P wispr -T /usr/bin/codesign -A
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db wl.crt
```

Verify with `security find-identity -v -p codesigning`. Changing signing
identity invalidates existing grants once, so re-add the app afterwards.

**`brew upgrade` breaks launch with a dyld error.** The app links Homebrew's
`libwhisper`/`libggml` by absolute path. Re-run `./build.sh` after upgrading.

## Layout

```
Sources/WisprLocal/
  main.swift              bootstrap; --selftest lives here
  AppDelegate.swift       menu bar, orchestrates the whole flow
  HotkeyMonitor.swift     CGEventTap on right ⌥
  AudioCapture.swift      AVAudioEngine + format conversion
  Engines/                the two backends behind one protocol
  TextInjector.swift      paste / type, secure-input detection
  HUDWindow.swift         the non-focus-stealing overlay
```
