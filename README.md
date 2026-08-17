# WisprLocal

Push-to-talk dictation for macOS. Hold **right ⌥**, speak, release — the text
lands wherever your cursor is. Runs entirely on your Mac, costs nothing, and
sends no audio anywhere. A free, local alternative to Wispr Flow.

![macOS](https://img.shields.io/badge/macOS-26%2B-black)
![Apple silicon](https://img.shields.io/badge/arch-arm64-black)
![License](https://img.shields.io/badge/license-MIT-black)

## What it needs from your Mac, and why

It asks for three permissions, two of which are the ones malware wants. That
deserves an answer before you install anything, not after:

- **Microphone** — only while you hold the key. The audio engine is started on
  press and stopped on release, so the orange recording dot appears exactly when
  you are dictating and never otherwise.
- **Input Monitoring** — to notice the key at all. The event tap subscribes to
  `flagsChanged` (modifier keys) and nothing else, and is created `.listenOnly`,
  so it cannot see the characters you type, in this or any other app. That's
  `HotkeyMonitor.swift`, and it's about forty lines — read it.
- **Accessibility** — to paste into the app you were already typing in. macOS
  gates synthetic keystrokes behind this grant.

No audio is ever written to disk, and nothing is sent anywhere. See
[what leaves your Mac](#what-leaves-your-mac-and-what-lands-on-disk) for the
full accounting.

## Requirements

| | Minimum | Notes |
|---|---|---|
| macOS | **26 Tahoe** | `SpeechAnalyzer` is new in 26 and has no back-deployment |
| Architecture | Apple silicon | Intel Macs on Tahoe are untested |
| Toolchain | Swift 6.2 (Xcode 26 CLT) | `xcode-select --install` |
| `whisper-cpp` | Homebrew | linked at build time, so it must be present even if you only use the Apple engine |
| Disk | ~600 MB | only if you use the Whisper engine |

The code still gates the Apple engine behind a runtime `#available` check and
keeps Whisper working without it, so the engine picker degrades gracefully. That
path just isn't tested on anything older, so 26 is what's claimed.

## Install

```bash
git clone https://github.com/Vrun1506/local-whisper-flow.git
cd local-whisper-flow
brew install whisper-cpp     # required: libwhisper is linked into the app
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
- **Recent dictations** — the 15 most recent, click to re-copy; **Clear history**
  wipes the lot
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
| Setup | none — macOS downloads the model | 574 MB one-time download |
| Live preview | yes | no |
| Strength | everyday dictation | accents, noise, jargon |

Measured on an M2 against 11 seconds of speech:

| | Apple Speech | Whisper |
|---|---|---|
| Model load (once per launch) | 0.4s | 0.4s |
| Decode | **0.4s** | **4.2s** |

Whisper's load figure is for a warm file cache. The first load after a reboot
pulls the whole 574 MB model off disk and takes several seconds; the menu bar
shows "Preparing Whisper…" while it does.

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
from a permissions problem. It also runs the filler-removal cases. The sample
defaults to Homebrew's `share/whisper-cpp/jfk.wav`; pass a path to use your own.

For the other half of the picture:

```bash
~/Applications/WisprLocal.app/Contents/MacOS/WisprLocal --permissions
```

prints the three grants with ✅/❌ and exits non-zero if any is missing.

One caveat on that flag: TCC attributes Accessibility and Input Monitoring to
the *responsible* process, which for anything started from a shell is the
terminal, not the app. So run from Terminal it can report ❌ for grants the
menu bar app really does hold. The **Permissions** submenu is the authoritative
answer; `--permissions` is for scripting and for the case where the app won't
start at all.

## What leaves your Mac, and what lands on disk

Nothing is sent anywhere. The only outbound request the app ever makes is the
one-time Whisper model download from Hugging Face over HTTPS (the Apple engine's
model comes from Apple, through the OS). That download is checked against a
pinned SHA-256 before anything loads it, and discarded if it doesn't match.
Audio is never written to disk at all.

Two things do persist, both in `~/Library/Application Support/WisprLocal/`:

| File | What it is |
|---|---|
| `ggml-large-v3-turbo-q5_0.bin` | the Whisper model, 574 MB |
| `history.json` | your last 50 transcripts, in plain text, `0600` |

The history exists so a failed paste is never a lost dictation. It is plain
text, so if you dictate something you would rather not keep, use **Recent
dictations › Clear history**, or delete the file.

The hotkey listener is worth being precise about, since "Input Monitoring"
sounds alarming: the event tap subscribes to `flagsChanged` only — modifier keys
— and is created `.listenOnly`, so it neither sees nor alters the characters you
type.

## Troubleshooting

**Hotkey does nothing.** Input Monitoring. Check the Permissions submenu; if it
shows ✅ but nothing happens, restart the app — the event tap is created at
launch.

**Transcribes but nothing is pasted.** Accessibility. Or the target app has
Secure Input on (password fields, some terminals) — the HUD says so explicitly,
and the text is on your clipboard and in Recent dictations either way.

**Permissions reset themselves after a rebuild.** Expected, and harmless. macOS
binds Accessibility and Input Monitoring to the binary's code hash, which
changes on every build, so an ad-hoc signature (`-s -` — what `build.sh` uses by
default) means re-granting them each time. Toggle WisprLocal off and on in both
panes, or run `./build.sh --reset-permissions` to be prompted cleanly.

If you rebuild often enough for that to grate, the optional section below fixes
it permanently.

**`brew upgrade` breaks launch with a dyld error.** The app links Homebrew's
`libwhisper`/`libggml` by absolute path. Re-run `./build.sh` after upgrading.

## Optional: a stable signing identity

**Skip this unless rebuilds are annoying you.** Everything works without it.

The re-granting happens because ad-hoc signatures have no stable identity for
macOS to remember. Signing with a real certificate — even a self-signed one —
keeps the designated requirement constant, so the grants stick across rebuilds.
`build.sh` picks up an identity named `WisprLocal Dev` automatically if one
exists, and falls back to ad-hoc if it doesn't.

Creating one means adding a code-signing root to **your login keychain**. Be
clear on what that is and isn't:

- It is **not** a Gatekeeper bypass and does **not** affect notarization. Trust
  is scoped to your login keychain and to the `codeSign` purpose only.
- It does mean anything signed with that key is treated by your Mac as validly
  signed. `-T /usr/bin/codesign` restricts use of the key to `codesign` itself;
  don't add `-A`, which would let any process use it without a prompt.
- The transport password below is throwaway — it protects the `.p12` for the
  seconds between export and import, and the file is deleted afterwards.

If that trade isn't one you want to make, don't make it. Re-granting two
toggles after a rebuild is a perfectly reasonable alternative.

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout wl.key -out wl.crt -subj "/CN=WisprLocal Dev" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
# -keypbe/-certpbe/-macalg are required: macOS can't read OpenSSL 3 defaults
openssl pkcs12 -export -inkey wl.key -in wl.crt -out wl.p12 -passout pass:wispr \
  -name "WisprLocal Dev" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import wl.p12 -k ~/Library/Keychains/login.keychain-db -P wispr -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db wl.crt
rm wl.key wl.p12          # the private key now lives in the keychain
```

Verify with `security find-identity -v -p codesigning`. Changing signing
identity invalidates existing grants once, so re-add the app afterwards.

To undo it later:

```bash
security delete-certificate -c "WisprLocal Dev" ~/Library/Keychains/login.keychain-db
```

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
