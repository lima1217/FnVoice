## Latency: SpeechTranscriber (macOS 26), retention processLifetime, prewarmed

| stage | p50 | p90 |
|---|---|---|
| prewarm (once, at launch) | 198 ms | |
| setup, first press | 0 ms | |
| setup, later presses | 0 ms | 0 ms |
| finalize (end of audio → text) | 110 ms | 126 ms |
| LLM refinement (9/10 sent by gate) | 1098 ms | 1663 ms |

Release → text, p50, excluding paste: 360 ms without LLM, 1458 ms with LLM (250 ms trailing capture + finalize + LLM).
