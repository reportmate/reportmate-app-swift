.PHONY: build test app app-open app-dmg clean

VERSION ?= $(shell date +%Y.%m.%d.%H%M)

build:
	swift build --product ReportMateMac

test:
	swift test

app:
	@scripts/build-app.sh --version=$(VERSION)

app-open:
	@scripts/build-app.sh --version=$(VERSION) --open

app-dmg:
	@scripts/build-app.sh --version=$(VERSION) --dmg

clean:
	rm -rf .build
