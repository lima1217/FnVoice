APP_NAME     := FnVoice
CONFIG       ?= release
BUILD_DIR    := build
APP          := $(BUILD_DIR)/$(APP_NAME).app
PROBE        := $(BUILD_DIR)/InjectProbe.app
INSTALL_DIR  ?= /Applications
ENTITLEMENTS := Resources/FnVoice.entitlements

# Override with SIGN_IDENTITY="My Cert". Empty → ad-hoc (permissions reset on every rebuild).
SIGN_IDENTITY ?= $(shell Tools/find-identity.sh)
SIGN := $(if $(strip $(SIGN_IDENTITY)),$(SIGN_IDENTITY),-)

# With only the Command Line Tools installed (no Xcode), Swift Testing exists but isn't on the
# default search path. Point the compiler and test runner at it when present.
CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer
TEST_FLAGS := $(if $(wildcard $(CLT_DEV)/Frameworks/Testing.framework),\
  -Xswiftc -F -Xswiftc $(CLT_DEV)/Frameworks -Xlinker -F -Xlinker $(CLT_DEV)/Frameworks \
  -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib)

.PHONY: all build bundle run install clean test verify smoke check hooks e2e eval eval-live eval-audio mock-llm bench icon coldstart ax-probe

all: build

build:
	swift build -c $(CONFIG) --product $(APP_NAME)
	swift build -c $(CONFIG) --product InjectProbe
	@$(MAKE) --no-print-directory bundle

bundle:
	@if [ "$(SIGN)" = "-" ]; then \
	  echo "warning: no code-signing identity found; signing ad-hoc."; \
	  echo "         Accessibility/Input Monitoring grants will reset on every rebuild. See README › Signing."; \
	fi
	@BIN_DIR="$$(swift build -c $(CONFIG) --show-bin-path)"; \
	Tools/bundle.sh "$(APP)" "$$BIN_DIR/$(APP_NAME)" Resources/Info.plist "$(SIGN)" $(ENTITLEMENTS) Resources/AppIcon.icns && \
	Tools/bundle.sh "$(PROBE)" "$$BIN_DIR/InjectProbe" Resources/InjectProbe-Info.plist "$(SIGN)"

run: build
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3
	open "$(APP)"

install: build
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	ditto "$(APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "installed to $(INSTALL_DIR)/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf .build $(BUILD_DIR)

test:
	swift test $(TEST_FLAGS)

verify:
	@[ -d "$(APP)" ] || $(MAKE) --no-print-directory build
	Tools/verify.sh "$(APP)"

# Live recognition path on 3 clips: fails on fallbacks or truncated text.
smoke: build eval-audio
	Tools/smoke.sh "$(CURDIR)/$(APP)"

# Everything that must hold before a commit; run by the pre-commit hook (`make hooks`).
check: test build verify smoke

hooks:
	git config core.hooksPath .githooks
	@echo "pre-commit hook enabled: runs make check"

# First Fn press after a cold start (quits the running app, idles GAP=120s, presses AFTER=5s after
# launch). The only check that opens the mic; too slow for `make check`. Relaunch with `make run` after.
coldstart: build
	GAP="$(GAP)" AFTER="$(AFTER)" Tools/coldstart.sh "$(CURDIR)/$(APP)"

# End-to-end injection into InjectProbe (needs Accessibility granted to FnVoice.app).
e2e: build
	Tools/e2e.sh "$(CURDIR)/$(APP)" "$(CURDIR)/$(PROBE)"

# Would the in-place swap work in a field? Default: an isolated Chrome textarea + contenteditable.
# TARGET=Name probes a running app's focused field; DELAY=5 probes whatever is frontmost after 5 s.
TARGET ?=
DELAY  ?=
ax-probe: build
	@APP="$(TARGET)" DELAY="$(DELAY)" Tools/ax-probe.sh "$(CURDIR)/$(APP)"

eval-audio:
	Tools/make-eval-audio.sh Eval/corpus.jsonl

# Runs through `open` so FnVoice.app (not the terminal) owns the speech-recognition permission.
# ENGINE=speechTranscriber|dictationTranscriber|legacy (default: the app's current choice)
GAP      ?= 120
AFTER    ?= 5
ENGINE   ?=
# GATE=all|englishOnly overrides the menu setting for which dictations reach the LLM.
GATE     ?=
EVAL_OUT ?= Eval/report.md
eval: build eval-audio
	@rm -f Eval/eval.log
	open -n -W --stdout "$(CURDIR)/Eval/eval.log" --stderr "$(CURDIR)/Eval/eval.log" \
	  --env FNVOICE_LLM_BASE_URL="$$FNVOICE_LLM_BASE_URL" --env FNVOICE_LLM_API_KEY="$$FNVOICE_LLM_API_KEY" \
	  --env FNVOICE_LLM_MODEL="$$FNVOICE_LLM_MODEL" \
	  "$(APP)" --args --eval "$(CURDIR)/Eval/corpus.jsonl" --out "$(CURDIR)/$(EVAL_OUT)" $(if $(ENGINE),--engine $(ENGINE)) $(if $(GATE),--gate $(GATE))
	@cat Eval/eval.log; echo; echo "report: $(EVAL_OUT)"

# Your own dictations from history.jsonl: re-runs today's corrections + refinement on the recorded
# recognizer text and scores it against what you left in the field. Also summarizes recorded
# latency (p50/p90), timeouts and guardrail rejections. Via `open` so the app can read its Keychain key.
# LIVE_ARGS e.g. "--limit 200", "--no-llm" (stats only), "--gate all"; HISTORY=path overrides the file.
LIVE_ARGS ?=
LIVE_OUT  ?= Eval/report-live.md
HISTORY   ?= $(HOME)/Library/Application Support/FnVoice/history.jsonl
eval-live: build
	@rm -f Eval/eval-live.log
	open -n -W --stdout "$(CURDIR)/Eval/eval-live.log" --stderr "$(CURDIR)/Eval/eval-live.log" \
	  --env FNVOICE_LLM_BASE_URL="$$FNVOICE_LLM_BASE_URL" --env FNVOICE_LLM_API_KEY="$$FNVOICE_LLM_API_KEY" \
	  --env FNVOICE_LLM_MODEL="$$FNVOICE_LLM_MODEL" \
	  "$(APP)" --args --eval-live "$(HISTORY)" --out "$(CURDIR)/$(LIVE_OUT)" $(LIVE_ARGS)
	@tail -3 Eval/eval-live.log; echo "report: $(LIVE_OUT)"

# Real-time latency benchmark of the SpeechAnalyzer path. BENCH_ARGS e.g. "--retention whileInUse --no-llm".
BENCH_ARGS ?=
BENCH_OUT  ?= Eval/latency.md
bench: build eval-audio
	@rm -f Eval/bench.log
	open -n -W --stdout "$(CURDIR)/Eval/bench.log" --stderr "$(CURDIR)/Eval/bench.log" \
	  "$(APP)" --args --latency-bench "$(CURDIR)/Eval/corpus.jsonl" --out "$(CURDIR)/$(BENCH_OUT)" \
	  $(if $(ENGINE),--engine $(ENGINE)) $(BENCH_ARGS)
	@cat "$(BENCH_OUT)"

# Regenerates Resources/AppIcon.icns from Tools/make-icon.swift.
icon:
	swift Tools/make-icon.swift build/icon
	iconutil -c icns build/icon/AppIcon.iconset -o Resources/AppIcon.icns

mock-llm:
	python3 Tests/MockLLM/server.py --port 8765
