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

.PHONY: all build bundle run install clean test verify e2e eval eval-audio mock-llm

all: build

build:
	swift build -c $(CONFIG) --product $(APP_NAME)
	swift build -c $(CONFIG) --product InjectProbe
	@$(MAKE) --no-print-directory bundle

bundle:
	@BIN_DIR="$$(swift build -c $(CONFIG) --show-bin-path)"; \
	rm -rf "$(APP)" "$(PROBE)"; \
	mkdir -p "$(APP)/Contents/MacOS" "$(PROBE)/Contents/MacOS"; \
	cp "$$BIN_DIR/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"; \
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"; \
	cp "$$BIN_DIR/InjectProbe" "$(PROBE)/Contents/MacOS/InjectProbe"; \
	cp Resources/InjectProbe-Info.plist "$(PROBE)/Contents/Info.plist"
	@if [ "$(SIGN)" = "-" ]; then \
	  echo "warning: no code-signing identity found; signing ad-hoc."; \
	  echo "         Accessibility/Input Monitoring grants will reset on every rebuild. See README › Signing."; \
	else echo "signing with: $(SIGN)"; fi
	codesign --force --options runtime --timestamp=none --entitlements $(ENTITLEMENTS) --sign "$(SIGN)" "$(APP)"
	codesign --force --timestamp=none --sign "$(SIGN)" "$(PROBE)"
	@echo "built $(APP)"

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

# End-to-end injection into InjectProbe (needs Accessibility granted to FnVoice.app).
e2e: build
	Tools/e2e.sh "$(CURDIR)/$(APP)" "$(CURDIR)/$(PROBE)"

eval-audio:
	Tools/make-eval-audio.sh Eval/corpus.jsonl

# Runs through `open` so FnVoice.app (not the terminal) owns the speech-recognition permission.
eval: build eval-audio
	@rm -f Eval/eval.log
	open -n -W --stdout "$(CURDIR)/Eval/eval.log" --stderr "$(CURDIR)/Eval/eval.log" \
	  --env FNVOICE_LLM_BASE_URL="$$FNVOICE_LLM_BASE_URL" --env FNVOICE_LLM_API_KEY="$$FNVOICE_LLM_API_KEY" \
	  --env FNVOICE_LLM_MODEL="$$FNVOICE_LLM_MODEL" \
	  "$(APP)" --args --eval "$(CURDIR)/Eval/corpus.jsonl" --out "$(CURDIR)/Eval/report.md"
	@cat Eval/eval.log; echo; echo "report: Eval/report.md"

mock-llm:
	python3 Tests/MockLLM/server.py --port 8765
