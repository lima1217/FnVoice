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
4. For long dictation, **double-tap Fn** instead: recording locks on the second press and keeps going after you let go (the capsule shows 🔒). Press Fn once more to finish, or Esc to cancel. Locked recording finalizes by itself after 10 minutes.

To start FnVoice at login, run `make install` and enable **登录时启动** in the menu. It uses `SMAppService.mainApp`, so it shows up under System Settings › General › Login Items. If you switch it off there, the menu item shows "needs approval", and clicking it opens that settings pane.

## Privacy

- **Speech is recognized on your Mac.** Audio never leaves the machine and is never saved to disk. On macOS 26 the SpeechAnalyzer engines are always on-device. The legacy engine (macOS 14/15) uses on-device recognition whenever Apple provides a model for the language; otherwise Apple's recognizer falls back to its server.
- **Only the transcribed text goes to the LLM you configure**, and only when **LLM 精修** is enabled in the menu. Text with no English letters and no known sound-alike (such as 配森) is never sent. Nothing else goes out: no audio, clipboard contents, or app names. FnVoice sends no telemetry.
- **Learning from edits** reads the field you dictated into, only right after a dictation, and keeps its contents in memory only. Just the corrected word pairs are written to disk, in `corrections.txt`. Turn it off in menu › 已学纠错 › 从我的修改中学习.
- **Dictation history** is on by default and stays on this Mac: each dictation appends one line to `~/Library/Application Support/FnVoice/history.jsonl` (owner-only permissions) with the recognized text, the refined and typed text, the text swapped in afterwards if any, stage timings, the refinement outcome, and the typed span as you left it after editing. It feeds `make eval-live`. Turn it off in menu › 听写历史 › 保留历史; turning it off stops new lines but doesn't delete the file. Above 10 MB the file is moved to `history.1.jsonl`, replacing the previous one.
- The API key is stored in the macOS Keychain. Transcripts appear in logs only at debug level and are redacted.

## Make targets

| target | what it does |
|---|---|
| `make build` | release build → signed `build/FnVoice.app` (+ `build/InjectProbe.app`) |
| `make run` | build, quit any running copy, launch |
| `make install` | copy to `/Applications` (`INSTALL_DIR=…` to change) |
| `make clean` | remove all build products |
| `make test` | unit + integration tests (Swift Testing; includes the mock LLM server) |
| `make check` | the pre-commit guardrail: test + build + verify + smoke (`make hooks` enables the hook once per clone) |
| `make smoke` | 3 clips through the live recognition path; fails on fallbacks or truncated text |
| `make verify` | codesign strict verify, entitlements, Info.plist lint, LSUIElement, Gatekeeper (informational) |
| `make e2e` | real injection into InjectProbe under ABC and your first enabled CJK input method, then an in-place swap of a "refined" text (checked to land, and to be skipped once you've typed on) and a word fix that must be learned; needs Accessibility for FnVoice.app |
| `make eval` | ASR + refinement over `Eval/corpus.jsonl`, writes `Eval/report.md` (`ENGINE=legacy\|speechTranscriber\|dictationTranscriber`, `EVAL_OUT=…`) |
| `make eval-live` | your own dictations from `history.jsonl`: recorded p50/p90 latency, timeout and guardrail rates, and today's refinement re-run on the recorded text, scored against what you left in the field (`LIVE_ARGS="--limit 200"`, `--no-llm` for stats only); writes `Eval/report-live.md` (git-ignored) |
| `make bench` | real-time latency benchmark of the SpeechAnalyzer path, writes `Eval/latency.md` |
| `make icon` | regenerate `Resources/AppIcon.icns` from `Tools/make-icon.swift` |
| `make mock-llm` | mock OpenAI-compatible server on `:8765` (key `test-key`) for trying Settings › Test |

## Signing (why it matters)

macOS ties Accessibility and Input Monitoring grants to the code signature. Ad-hoc signatures change on every build, so every rebuild looks like a new app and you would have to re-grant. The Makefile signs with a stable identity, chosen in this order: any identity containing "FnVoice", then "Developer ID Application", then "Apple Development", then the first valid code-signing identity. Override it explicitly:

```bash
make build SIGN_IDENTITY="FnVoice Local Signing"
```

To create a dedicated local identity: open Keychain Access › Certificate Assistant › Create a Certificate…, name it `FnVoice Local Signing`, set Identity Type to *Self Signed Root* and Certificate Type to *Code Signing*. Builds are signed with hardened runtime and the `audio-input` entitlement. They are not notarized, so `spctl` reports "rejected"; that is expected for local builds.

## How it works

```
Fn down ─▶ arming (150 ms) ─▶ recording ─▶ Fn up ─▶ finalizing ─▶ injecting ─▶ refining in place ─▶ replacing ─▶ idle
             │ tap/combo → idle   │ Esc → idle          │ Esc → idle     (field readable over Accessibility)
                                                                      └▶ refining ─▶ injecting ─▶ idle
                                                                          │ Esc → idle  (field not readable)
Fn tap ─▶ tapped (350 ms) ─▶ Fn down ─▶ recording, locked (Fn up ignored) ─▶ Fn down ─▶ finalizing ─▶ …
```

- **Type first, refine in place.** The LLM is off the path to the first text. At Fn-up the raw transcript is typed at once (about 0.4 s after release), the refinement request goes out in parallel, and when the answer differs it is swapped in where the raw text was typed: FnVoice reads the focused field over Accessibility, checks that the raw text still ends exactly at the caret, selects it and pastes the answer. Anything else leaves the raw text alone: you typed on, pressed Enter in a chat box, switched apps, selected something, or the field refused the selection. Esc is not claimed once text is out, and pressing Fn while the answer is pending abandons it and starts the next dictation. Whether a field can be read is probed at Fn-down; fields that can't (terminals, some editors, password fields) keep the old behaviour of waiting for the LLM and typing once; meanwhile the capsule shows the raw transcript dimmed, so you can already read what was heard.
- **State machine** (`DictationMachine`) is a pure reducer. Every async result carries a session id, so a late result from a cancelled dictation can't leak into the next one. Fn presses during refining, injecting or replacing are ignored. A quick tap opens a 350 ms window; a second press inside it starts recording immediately with `locked` set, so Fn-up is ignored and the next Fn press stops. An Fn+key combo on that locking press aborts, since it was a shortcut, not a dictation. Duration limits send `finish`, which stops locked and held recording alike. Everything a phase needs (how the recording is held, whether a paste is followed by a swap, an LLM answer that arrived mid-paste) rides in the phase's payload rather than in side flags, so nothing is reset between dictations. The machine also says when a dictation's text is final (`settle`), so the controller never has to infer it from the phase.
- **Fn key** (`FnKeyTracker` + `HotkeyMonitor`): a CGEvent tap identifies Fn by key code 63/179 on `flagsChanged`, never by the Fn flag, since arrow and F-keys carry that flag too. Only a bare Fn press is claimed and suppressed. Fn+key combos pass through untouched. If the system disables the tap after a timeout, it is re-enabled and the tracker reset.
- **Recognition** (`AnalyzerCapture` on macOS 26 and `SpeechCapture` for legacy, behind the `LiveTranscriber` protocol). Legacy runs on-device when available, punctuation on, and `contextualStrings` seeded with ~70 tech terms plus your own (menu › 编辑词汇表…). Capture continues 250 ms after Fn-up so the last syllable isn't clipped, then waits for `isFinal` for at most 1.5 s. Server-based sessions auto-finalize at 55 s, before Apple's ~1 min cap; locked on-device recording at 10 minutes. Audio route changes (for example AirPods switching to HFP) rebuild the engine instead of crashing. Recognition errors are shown in the capsule; they don't vanish silently.
- **Waveform**: RMS → dBFS, with a −50 dB noise floor and −12 dB ceiling, mapped to 0…1. Attack is 40%, release 15%, and each bar has ±4% jitter around weights [0.5, 0.8, 1.0, 0.75, 0.55]. Redrawn via display link. Reduce Motion disables jitter, spring and scale.
- **Injection** (`TextInjector`):
  - It refuses to type while Secure Input is on, for example in a password field.
  - If the app you started in is no longer frontmost (say, during a slow LLM call), it copies the text to the clipboard instead of typing it into the wrong window.
  - Otherwise it snapshots every pasteboard item and type, then writes the text marked `org.nspasteboard.TransientType`/`ConcealedType`.
  - For CJK input methods it switches to ABC/US, waits until the switch has actually taken effect, sends ⌘V using the "v" key in the current layout, then switches back and verifies.
  - The clipboard is restored 300 ms later, but only if nothing else was copied in the meantime.
- **Spacing** (`TextFormatter`): every injected text gets one space on both sides of an English word next to Chinese or Japanese (`用 Python 写`). Numbers stay attached (`5分钟`), there is no space next to full-width punctuation, and English and Korean spacing is left alone. Only whitespace changes, never characters.
- **Learning from your edits** (`EditWatcher`, `CorrectionExtractor`, `CorrectionStore`; menu › 已学纠错):
  - After the text is final (typed, or swapped in by the LLM), FnVoice reads the focused field over Accessibility every 0.4 s. It stops when the field loses focus, you switch apps, the pasted text disappears (for example, a chat box cleared by Enter), the next dictation starts, or 3 minutes pass. It skips password fields and fields over 20,000 characters.
  - It diffs what it pasted against the last reading that stayed unchanged for one poll. Readings in the middle of an IME composition are therefore ignored. It keeps only small word substitutions: no punctuation edits, no pure insertions or deletions, and nothing from a sentence that is more than 50% rewritten. A one-character Chinese fix (带→代) is widened with its neighbour (带码→代码), so it can't rewrite every 带.
  - Learned pairs are saved to `~/Library/Application Support/FnVoice/corrections.txt`, which you can edit. **Seen once**, the corrected word joins the recognition vocabulary and the pair is shown to the LLM, and text containing the mistake passes the refinement gate. **Seen twice**, it is replaced automatically, with no LLM needed. Latin words match whole words only. Changing an auto-replaced word back counts against the rule.
- **LLM refinement** (`Refiner`):
  - **Scope** (menu › LLM 精修): **精修所有听写** (default) sends every dictation. **仅在含英文时精修** sends only text with English letters, a known sound-alike like 配森, or a mistake you corrected before; pure Chinese is then typed ~1.3 s sooner, but English terms heard as Chinese words (`都可能`→Docker) and Chinese homophones go unfixed.
  - The prompt names three kinds of recognition error, with examples kept out of the eval corpus: garbled English (`pie torch`→PyTorch), English terms written as Chinese sound-alikes (`瑞迪斯`→Redis), and Chinese homophones that don't fit the sentence (`单原测试`→单元测试). It asks the model to read the whole sentence first and fix a word only when one intended word clearly fits better.
  - If no reply arrives within 2 s, an identical second request races the first, and the first answer wins. DeepSeek's median is ~1.3 s, but about 1 call in 40 took 4–12 s. The HTTPS connection is reused across dictations.
  - The prompt includes your vocabulary (built-in terms plus 编辑词汇表…) as "terms this speaker uses". SpeechTranscriber barely reacts to `contextualStrings`, but the LLM does.
  - For DeepSeek hosts, `thinking: {type: disabled}` is sent automatically. `deepseek-flash` otherwise produces 200–800 hidden reasoning tokens (3–6 s) for a ~10-token correction.
  - Uses temperature 0 and a 4 s hard timeout. The transcript is wrapped in `<transcript>` tags, and the prompt says it is data, not instructions. In a readable field the raw text is already typed by then, so a slow answer only delays the swap.
  - The output is cleaned of fences, prefixes and quotes, then checked by an **edit guardrail**. The guardrail tokenizes the text (Latin word = 1 token, CJK char = 1 token) and diffs it into hunks. Replacing a short span with 1–2 Latin words counts as one edit (配森→Python); every other change costs one edit per token.
  - Output that changes more than 30% is discarded.
  - Any error, timeout, cancellation or guardrail rejection injects the raw transcript. Your words are never lost.
  - The API key is stored in the Keychain; clearing the field and saving deletes it.

Logs: `log stream --predicate 'subsystem == "com.local.fnvoice"' --info`. Transcripts are logged only at debug level and redacted. Every dictation logs one line such as `latency engine=speechTranscriber partials=12 setup=0ms asr=360ms llm=1100ms paste=40ms release→text=400ms replace=60ms` at notice level (`replace` is LLM answer → swapped in; `-` when nothing was swapped), so it is kept on disk and `log show --last 7d --predicate 'subsystem == "com.local.fnvoice"' | grep latency` gives real usage statistics (`setup` includes opening the microphone, which the bench below does not measure), and `release-to-inject` is also a signpost interval in Instruments › Points of Interest.

## Latency

`make bench` streams corpus clips through the live SpeechAnalyzer code path at real-time pace and reports per-stage times. Results for 10 clips with SpeechTranscriber and `deepseek-flash`, thinking disabled:

| Stage | p50 | p90 |
|---|---|---|
| setup, first press after launch | 0 ms (prewarmed at launch; 170 ms without) | |
| trailing capture after Fn-up | 250 ms (fixed) | |
| finalize, end of audio → text | 110 ms | 126 ms |
| LLM refinement | 1098 ms | 1663 ms |
| **release → text** | **~360 ms without LLM, ~1.46 s with LLM** | |

Before thinking was disabled, the LLM stage alone took 2.8–4.7 s, and one probe call took 6.0 s, past the 4 s timeout. Options: `make bench BENCH_ARGS="--retention whileInUse"`, `--no-llm`, `--llm-probe` (prints DeepSeek token usage and timing; the key is never printed). The reports are in `Eval/latency-*.md`.

The mic starts before the analyzer is ready, and audio is buffered meanwhile, so words spoken right at Fn-down aren't lost. The model is kept loaded for the app's lifetime (`modelRetention: .processLifetime`). Its memory cost hasn't been measured.

## Recognition engines

Choose one in the menu under **识别引擎**. The choice is remembered.

| Engine | OS | Mean CER, raw | + DeepSeek refinement |
|---|---|---|---|
| **SpeechTranscriber** (default) | macOS 26+ | **11.9%** | **2.9%** (5.9% with the earlier prompt and English-only gate) |
| SpeechTranscriber with `.fastResults` (removed, see below) | macOS 26+ | 14.0% | 9.0% |
| DictationTranscriber | macOS 26+ | 18.3% | not run |
| SFSpeechRecognizer (legacy) | macOS 14+ | 18.7% | 16.6% |

Measured with `make eval` on the 40 mixed zh/en clips in `Eval/corpus.jsonl` (the corpus now also has 20 pure-Chinese clips, reported separately): synthesized speech (Tingting voice), on-device, model `deepseek-flash`. The false-correction rate was 0/20 in both refinement runs. The reports are in `Eval/report-*.md`.

Why SpeechTranscriber plus the LLM works so well together: legacy turns English words into Chinese sound-alikes (Python → "P3", token → "巧克力"), which an LLM can rarely recover. SpeechTranscriber writes English as near-miss Latin spellings instead (`piston`, `Qberneet`, `sleck`), and the LLM fixes those reliably. Per clip, it beats legacy on 17, loses on 9 and ties on 14.

**No live text while speaking.** SpeechTranscriber sends no text until Fn is released, so the capsule shows only the waveform while you talk. A "Show Live Text" option that turned on `.fastResults` shipped briefly and was removed:
- It streamed text into the capsule from about 1.2 s in (on 40/40 clips), and finalize dropped from ~110 ms to ~55 ms.
- But the final text got worse: CER after DeepSeek went from 2.9% to 9.0% (`Eval/report-speechTranscriber-llm.md` vs `Eval/report-speechTranscriber-fast-llm.md`). Three times the errors for a preview wasn't worth it.
- Running a fast analyzer for display next to an accurate one for typing doesn't work. The two share Apple's speech service, and the accurate one intermittently returned a single character.

Refinement results on the default engine:
- Vocabulary in the prompt fixed `bok→bug`, `PER greview→PR review` and `cle→CLI`.
- The earlier "fix only if obvious" prompt left pure-Chinese homophones alone (`返回只→返回值`, `钱端→前端`), even with every dictation sent. The current prompt fixes them, plus `都可能→Docker`. On the 20 pure-Chinese clips CER went from 0.7% to 0.0%, and across all 60 clips from 3.6% to 2.0%, in two runs.
- False corrections stayed at 0/28. That set includes sentences built to tempt a homophone "fix" (`我在会议室等你`, `下次再说`).

**The errors that remain** after refinement (2.9% on the mixed set) are English terms the recognizer turned into something with no phonetic trace of the term: `Stole` for Xcode, `even read` for README, `铺设` for push, `算` for JSON. Two attempts to recover them with the LLM were measured and dropped (`Eval/report-speechTranscriber-latinrule-llm.md`, `Eval/report-speechTranscriber-unsure-llm.md`, each run twice with `--gate all`):
- A prompt rule that a nonsense Latin word next to Chinese is a misheard term to be matched by sound against the term list fixed none of them and lost a context fix (`发→把`): 3.1% instead of 2.9%.
- Passing the recognizer's own confidence (`.transcriptionConfidence`) and listing the words below 0.5 as "unsure" in the request. The signal itself is precise: 9 of the 28 term errors fall below 0.5 and only 2 correct spans do, across 60 clips. But the model guessed where the sound gave it nothing (`Stole→Swift`, `算→Swift`); a rule to leave such words alone stopped the second guess, not the first: 3.3%. False corrections stayed 0/28 throughout.
- `Result.alternatives` always holds just the text itself, so there is no n-best list to offer instead.

Some behavior to know about:
- SpeechTranscriber inserts a space before Latin words only (`用 Python写`); `TextFormatter` normalizes that. It sometimes ends with `。`.
- Custom vocabulary (`contextualStrings`) seemed to have little effect on it in these runs.
- On macOS 14/15 every engine falls back to legacy.
- The first time you dictate in a language without a SpeechAnalyzer model installed, FnVoice downloads the model in the background and uses legacy until it's ready.

## Evaluation

`Eval/corpus.jsonl` holds 40 mixed Chinese/English dictation cases and 20 already-correct sentences.

- `make eval-audio` synthesizes the missing audio with `say`. Replace the files in `Eval/audio/` with real recordings for a harsher test.
- `make eval` runs the real recognizer, then refinement, and reports mean CER before and after refinement, plus the **false-correction rate** on correct sentences (target: 0%).

The LLM comes from `FNVOICE_LLM_BASE_URL`, `FNVOICE_LLM_API_KEY` and `FNVOICE_LLM_MODEL`, or else from the app's settings:

```bash
FNVOICE_LLM_BASE_URL=https://api.deepseek.com/v1 FNVOICE_LLM_API_KEY=sk-... FNVOICE_LLM_MODEL=deepseek-chat make eval
FNVOICE_LLM_BASE_URL=off make eval ENGINE=legacy EVAL_OUT=Eval/report-legacy.md   # ASR only
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
