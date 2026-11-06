# Manual test checklist

Automated tests cover the logic; this checklist covers what only a real system can show. Run it after `make install` with all permissions granted, Dictation on, and "Press 🌐 key to: Do Nothing".

Test phrase: **我在用 Python 写一个 JSON 解析器** (say it as written).

## Injection matrix

For each cell, check that: ① the text arrives exactly, ② the input method is the same afterwards, and ③ the clipboard holds what you copied before (copy an image or rich text first to test multi-type restore).

| App ↓ / IME → | ABC | System Pinyin | Sogou | WeChat IME (微信输入法) | Japanese (Kotoeri) |
|---|---|---|---|---|---|
| TextEdit | | | | | |
| Safari (address bar + textarea) | | | | | |
| Chrome (Google Docs) | | | | | |
| VS Code (editor + terminal panel) | | | | | |
| Terminal / iTerm2 | | | | | |
| Slack (Electron) | | | | | |
| WeChat | | | | | |

## Edge cases

| Scenario | Expected |
|---|---|
| Tap Fn briefly (<150 ms) | nothing happens, no capsule |
| Fn+↑ / Fn+F5 / Fn+Delete | the normal system action; no dictation |
| Hold Fn, stay silent, release | capsule disappears, nothing typed |
| Hold Fn, speak, press Esc before releasing | capsule disappears, nothing typed, Esc not sent to the app |
| LLM on, in TextEdit/Notes: release | raw text appears in ~0.4 s and the capsule hides; 1–2 s later a misheard term (piston → Python) changes in place, caret stays at the end |
| LLM on, in TextEdit: release, keep typing right away | the raw text stays; no swap, your typing is not disturbed |
| LLM on, in a chat box: release, press Enter before the answer | message sent with the raw text; nothing else happens |
| LLM on, in TextEdit: release, press Esc while waiting for the answer | Esc reaches TextEdit; the swap still happens |
| LLM on, in TextEdit: release, press Fn again before the answer | the first text stays raw; the second dictation works normally |
| LLM on, in Terminal/iTerm: release | capsule shows "Refining…" and the text is typed once, after the answer (old path) |
| LLM on, in Terminal: release, then Esc during "Refining…" | nothing typed |
| LLM on, in Terminal: release, then switch app during "Refining…" | not typed; capsule says "App changed — text copied to clipboard"; ⌘V pastes it |
| Focus a password field (e.g. Safari login) and dictate | capsule says "Secure input is on…", nothing typed |
| Connect AirPods while holding Fn | no crash; dictation continues or ends cleanly |
| Speak continuously for 70 s (server recognition) | auto-finalizes around 55 s and types what was said |
| LLM base URL pointing at a dead host | after ≤4 s the raw text is typed |
| LLM model `rewrite` on `make mock-llm` | raw text typed (guardrail), not the rewrite |
| Settings: clear API key, Save, reopen | field empty; Keychain item gone (`security find-generic-password -s com.local.fnvoice.llm` fails) |
| Switch language to English, dictate English | English text |
| Quit and relaunch | language and LLM toggle remembered |
| Dictate with a fullscreen app / on a second display | capsule appears on the screen with the focused window, above fullscreen content |
| System Settings › Accessibility › Reduce Motion on | capsule fades in and out, no spring or scale, bars without jitter |
| `make build` twice, relaunch | Accessibility still granted (stable signature) |
| Turn system Dictation off, dictate | capsule says "Turn on Dictation in System Settings › Keyboard" |
| Menu › Launch at Login on, log out and back in | FnVoice starts; System Settings › Login Items lists it; toggling off removes it |
| SpeechTranscriber, dictate a long sentence | only the waveform while speaking; text appears in the capsule on release, before it is typed |
