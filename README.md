# FnVoice

Hold **Fn** to dictate, release to type the text into whatever field has focus. Menu-bar only (no Dock icon), Apple Speech streaming recognition, default language Simplified Chinese, optional conservative LLM clean-up for mixed Chinese/English.

## Quick start

Requirements: macOS 14+, Swift 6 toolchain (Xcode or Command Line Tools).

```bash
make run
```

On first launch, grant what the app asks for: Microphone, Speech Recognition, and Accessibility. If something is missing, the menu-bar icon's menu shows a **⚠︎ Grant …** item that opens the right System Settings pane. Then:

1. **System Settings › Keyboard › Dictation: On.** Apple's recognizer refuses to run while system Dictation is off ("Siri and Dictation are disabled").
2. **System Settings › Keyboard › "Press 🌐 key to": Do Nothing.** FnVoice swallows the Fn event, but macOS may still show the emoji picker or switch input source. The app prompts once and keeps a menu item until it's set.
3. Click into any text field, hold Fn, speak, release. Press **Esc** to cancel at any point before the text is typed.

## Make targets

| target | what it does |
|---|---|
| `make build` | release build → signed `build/FnVoice.app` (+ `build/InjectProbe.app`) |
| `make run` | build, quit any running copy, launch |
| `make install` | copy to `/Applications` (`INSTALL_DIR=…` to change) |
| `make clean` | remove all build products |
| `make test` | unit + integration tests (Swift Testing; includes the mock LLM server) |
| `make verify` | codesign strict verify, entitlements, Info.plist lint, LSUIElement, Gatekeeper (informational) |
| `make e2e` | real injection into InjectProbe under ABC and your first enabled CJK input method; needs Accessibility for FnVoice.app |
| `make eval` | ASR + refinement over `Eval/corpus.jsonl`, writes `Eval/report.md` |
| `make mock-llm` | mock OpenAI-compatible server on `:8765` (key `test-key`) for trying Settings › Test |

## Signing (why it matters)

macOS ties Accessibility and Input Monitoring grants to the code signature. Ad-hoc signatures change on every build, so every rebuild looks like a new app and you would have to re-grant. The Makefile signs with a stable identity, chosen in this order: any identity containing "FnVoice", then "Developer ID Application", then "Apple Development", then the first valid code-signing identity. Override it explicitly:

```bash
make build SIGN_IDENTITY="FnVoice Local Signing"
```

To create a dedicated local identity: open Keychain Access › Certificate Assistant › Create a Certificate…, name it `FnVoice Local Signing`, set Identity Type to *Self Signed Root* and Certificate Type to *Code Signing*. Builds are signed with hardened runtime and the `audio-input` entitlement. They are not notarized, so `spctl` reports "rejected"; that is expected for local builds.

## How it works

```
Fn down ─▶ arming (150 ms) ─▶ recording ─▶ Fn up ─▶ finalizing ─▶ [refining] ─▶ injecting ─▶ idle
             │ tap/combo → idle   │ Esc → idle          │ Esc → idle     │ Esc → idle
```

- **State machine** (`DictationMachine`) is a pure reducer. Every async result carries a session id, so a late result from a cancelled dictation can't leak into the next one. Fn presses during refining or injecting are ignored.
- **Fn key** (`FnKeyTracker` + `HotkeyMonitor`): a CGEvent tap identifies Fn by key code 63/179 on `flagsChanged`, never by the Fn flag, since arrow and F-keys carry that flag too. Only a bare Fn press is claimed and suppressed. Fn+key combos pass through untouched. If the system disables the tap after a timeout, it is re-enabled and the tracker reset.
- **Recognition** (`SpeechCapture`): on-device when available, punctuation on, and `contextualStrings` seeded with ~70 tech terms plus your own (menu › Edit Vocabulary…). Capture continues 250 ms after Fn-up so the last syllable isn't clipped, then waits for `isFinal` for at most 1.5 s. Server-based sessions auto-finalize at 55 s, before Apple's ~1 min cap. Audio route changes (for example AirPods switching to HFP) rebuild the engine instead of crashing. Recognition errors are shown in the capsule; they don't vanish silently.
- **Waveform**: RMS → dBFS, with a −50 dB noise floor and −12 dB ceiling, mapped to 0…1. Attack is 40%, release 15%, and each bar has ±4% jitter around weights [0.5, 0.8, 1.0, 0.75, 0.55]. Redrawn via display link. Reduce Motion disables jitter, spring and scale.
- **Injection** (`TextInjector`):
  - It refuses to type while Secure Input is on, for example in a password field.
  - If the app you started in is no longer frontmost (say, during a slow LLM call), it copies the text to the clipboard instead of typing it into the wrong window.
  - Otherwise it snapshots every pasteboard item and type, then writes the text marked `org.nspasteboard.TransientType`/`ConcealedType`.
  - For CJK input methods it switches to ABC/US, waits until the switch has actually taken effect, sends ⌘V using the "v" key in the current layout, then switches back and verifies.
  - The clipboard is restored 300 ms later, but only if nothing else was copied in the meantime.
- **LLM refinement** (`Refiner`):
  - Uses temperature 0 and a 4 s hard timeout. The transcript is wrapped in `<transcript>` tags, and the prompt says it is data, not instructions.
  - The output is cleaned of fences, prefixes and quotes, then checked by an **edit guardrail**. The guardrail tokenizes the text (Latin word = 1 token, CJK char = 1 token) and diffs it into hunks. Replacing a short span with 1–2 Latin words counts as one edit (配森→Python); every other change costs one edit per token.
  - Output that changes more than 30% is discarded.
  - Any error, timeout, cancellation or guardrail rejection injects the raw transcript. Your words are never lost.
  - The API key is stored in the Keychain; clearing the field and saving deletes it.

Logs: `log stream --predicate 'subsystem == "com.local.fnvoice"' --info`. Transcripts are logged only at debug level and redacted. Latency from release to injection is a signpost interval (`release-to-inject`) you can view in Instruments › Points of Interest.

## Evaluation

`Eval/corpus.jsonl` holds 40 mixed Chinese/English dictation cases and 20 already-correct sentences.

- `make eval-audio` synthesizes the missing audio with `say`. Replace the files in `Eval/audio/` with real recordings for a harsher test.
- `make eval` runs the real recognizer, then refinement, and reports mean CER before and after refinement, plus the **false-correction rate** on correct sentences (target: 0%).

The LLM comes from `FNVOICE_LLM_BASE_URL`, `FNVOICE_LLM_API_KEY` and `FNVOICE_LLM_MODEL`, or else from the app's settings:

```bash
FNVOICE_LLM_BASE_URL=https://api.openai.com/v1 FNVOICE_LLM_API_KEY=sk-... FNVOICE_LLM_MODEL=gpt-4o-mini make eval
```

Run it through `make`: the Makefile launches the app with `open`, so FnVoice.app itself (not your terminal) holds the speech-recognition permission.

## Layout

```
Sources/FnVoiceCore   pure logic: state machine, key tracker, waveform math, injector, LLM client, guardrail, metrics
Sources/FnVoice       AppKit app: event tap, Speech/AVAudioEngine, capsule panel, menu, settings, Keychain, eval & self-test modes
Sources/InjectProbe   NSTextView app that mirrors its text to a file (e2e target)
Tests/                Swift Testing suites + MockLLM/server.py
Tools/                verify, e2e, eval-audio, signing-identity scripts
docs/MANUAL_TEST.md   cross-app / cross-IME checklist
```
