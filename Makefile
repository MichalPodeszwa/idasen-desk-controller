PROJECT := Idasen.xcodeproj
SCHEME := Idasen
DERIVED_DATA := build/DerivedData
SWIFT_SOURCES := App Packages Tools

VERSION_ARGS := $(if $(MARKETING_VERSION),MARKETING_VERSION=$(MARKETING_VERSION)) \
	$(if $(CURRENT_PROJECT_VERSION),CURRENT_PROJECT_VERSION=$(CURRENT_PROJECT_VERSION))

.PHONY: generate test test-scripts build e2e hw-log lint format app-path clean

generate:
	xcodegen generate

test:
	swift test --package-path Packages/DeskKit

test-scripts:
	scripts/ci/test-version-from-tag.sh
	scripts/ci/test-hw-log.sh

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED_DATA) $(VERSION_ARGS) build

e2e:
	scripts/e2e-sim.sh

hw-log:
	scripts/hw-log.sh $(HW_LOG_ARGS)

lint:
	swift format lint --recursive --strict $(SWIFT_SOURCES)

format:
	swift format format --in-place --recursive $(SWIFT_SOURCES)

app-path:
	@echo $(CURDIR)/$(DERIVED_DATA)/Build/Products/Debug/Idasen.app

clean:
	rm -rf build $(PROJECT) Packages/DeskKit/.build
