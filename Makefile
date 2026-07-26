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

XCODEBUILD := xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
	-configuration $(CONFIGURATION) -derivedDataPath "$(DERIVED_DATA)"

.PHONY: build run clean

build:
	$(XCODEBUILD) build

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
