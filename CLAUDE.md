# FnVoice — agent notes

`make check` is the guardrail (tests, build, verify, live-path smoke); the pre-commit hook runs it once `make hooks` is set. The Makefile lists every other target.

Facts no config file shows:

- **Installed copy is what runs.** The user runs `/Applications/FnVoice.app` (also launched at login); a change reaches them only after `make install`.
- **TCC-bound modes launch via `open`.** `eval`, `bench`, `smoke` and `e2e` start FnVoice.app with `open -W`, so the app — not the terminal — holds mic, speech and Accessibility permission. New modes that touch those follow the same pattern.
- **Logs:** `/usr/bin/log show --last 10m --info --predicate 'subsystem == "com.local.fnvoice"'`. Use the full path (zsh shadows `log`); `--info` is needed for everything except the `latency` line, which is logged at notice level so it survives restarts (info lines live only in process memory and are lost at every `make install`). Each dictation writes one `latency engine=… partials=… setup=… asr=… llm=… paste=…` line; `partials` counts text updates while Fn was held (0 is normal for SpeechTranscriber, which reports nothing until release).
- **Real usage data:** `history.jsonl` (see README › Privacy) has every dictation's texts, timings and the user's final edit; `make eval-live` replays it through current refinement. Its report holds the user's real text, so it stays git-ignored; never commit or paste it elsewhere.
- **Live path vs eval.** `make eval` transcribes files through a separate path; only `make bench` / `make smoke` run the live `AnalyzerSession`. Verify recognition changes there.
- **Menu-bar app text fields.** ⌘V/⌘C/⌘A route through `NSApp.mainMenu` even when no menu is visible, so every app target installs an Edit menu; windows call `NSApp.forceActivate()` to take keyboard focus.
- **Apple Speech quirks** (asset status, `.fastResults`, two-analyzer interference, DeepSeek thinking) are documented with measurements at their call sites in `Sources/FnVoice/AnalyzerCapture.swift` and `Sources/FnVoiceCore/LLMClient.swift`; read them before changing recognition or refinement.
