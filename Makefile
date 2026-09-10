.PHONY: build test app app-open app-dmg app-pkg clean

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

app-pkg:
	@scripts/build-app.sh --version=$(VERSION) --pkg

clean:
	rm -rf .build
