## Latency: SpeechTranscriber (macOS 26), retention whileInUse

| stage | p50 | p90 |
|---|---|---|
| setup, first press | 170 ms | |
| setup, later presses | 0 ms | 0 ms |
| finalize (end of audio → text) | 113 ms | 142 ms |
| LLM refinement (9/10 sent by gate) | 1179 ms | 1583 ms |

Release → text, p50, excluding paste: 363 ms without LLM, 1542 ms with LLM (250 ms trailing capture + finalize + LLM).
