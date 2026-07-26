# Net Camera build harness.
#
# Thin wrapper over xcodebuild so builds and launches are runnable unattended.
# xcodebuild on some machines emits unrelated "CoreSimulator is out of date" /
# "Unable to load simulator devices" noise; this is a macOS-only project, so
# success is judged solely by xcodebuild's exit status, never by its output.

PROJECT       := Net Camera.xcodeproj
SCHEME        := Net Camera
CONFIGURATION ?= Debug
DERIVED_DATA  := build
DESTINATION   := platform=macOS

XCODEBUILD := xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
	-configuration $(CONFIGURATION) -derivedDataPath "$(DERIVED_DATA)"

.PHONY: build check run clean

build:
	$(XCODEBUILD) build

# The one place in this project where exit status is not sufficient evidence.
# `xcodebuild test` exits 0 when it runs no tests at all, so a scheme whose
# <Testables> list is empty or names a stale BlueprintIdentifier reports a
# green run having proved nothing. The count of executed test cases is
# therefore asserted alongside the exit status, and a run of zero is a
# failure. The count comes from the per-case lines XCTest emits, one apiece.
check:
	@set -o pipefail; \
	mkdir -p "$(DERIVED_DATA)"; \
	log="$(DERIVED_DATA)/check.log"; \
	$(XCODEBUILD) -destination '$(DESTINATION)' test 2>&1 | tee "$$log"; \
	status=$$?; \
	if [ $$status -ne 0 ]; then \
		echo "make check: xcodebuild test failed (exit $$status)" >&2; \
		exit $$status; \
	fi; \
	ran=`grep -c "^Test Case .* started\.$$" "$$log" || true`; \
	if [ "$$ran" -eq 0 ]; then \
		echo "make check: xcodebuild exited 0 but executed 0 tests --" >&2; \
		echo "  the scheme's Testables are not wired to the test target." >&2; \
		exit 1; \
	fi; \
	echo "make check: executed $$ran test(s)"

# Ask the project where the product landed rather than hardcoding a path.
run: build
	@app=`$(XCODEBUILD) -showBuildSettings 2>/dev/null \
	  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{d=$$2} / FULL_PRODUCT_NAME = /{n=$$2} \
	                 END{if (d != "" && n != "") print d "/" n}'`; \
	if [ -z "$$app" ] || [ ! -d "$$app" ]; then \
		echo "make run: could not locate the built app bundle" >&2; exit 1; \
	fi; \
	echo "Launching $$app"; \
	open "$$app"

clean:
	$(XCODEBUILD) clean
	rm -rf "$(DERIVED_DATA)"
