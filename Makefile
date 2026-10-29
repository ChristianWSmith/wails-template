APP := wails-template
GOPATH_BIN := $(shell go env GOPATH)/bin
# Pin the CLI to the same version the app imports: go.mod is the single
# source of truth (Dependabot bumps it like any other dependency).
WAILS_VERSION := $(shell go list -m -f '{{.Version}}' github.com/wailsapp/wails/v3)

# The stock Taskfiles shell out to `wails3`, so the CLI must be on PATH.
export PATH := $(GOPATH_BIN):$(PATH)

.PHONY: build run dev test lint fmt vet linux-deps ensure-wails3 package artifact artifact-name clean

# Installs wails3 into GOPATH/bin when missing or at a different version
# than go.mod pins.
ensure-wails3:
	@command -v wails3 >/dev/null 2>&1 && \
	  [ "$$(wails3 version 2>/dev/null | head -1 | tr -d 'v' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')" = "$(WAILS_VERSION:v%=%)" ] || \
	  go install github.com/wailsapp/wails/v3/cmd/wails3@$(WAILS_VERSION)

build: ensure-wails3
	wails3 build

run: build
	./bin/$(APP)

dev: ensure-wails3
	wails3 dev

# frontend/dist is embedded into the binary (//go:embed) but only exists
# after a frontend build. Stub it so plain `go vet` / `go test` compile on
# a fresh clone; the first `make build` replaces it with the real bundle.
frontend/dist:
	mkdir -p frontend/dist && touch frontend/dist/index.html

test: | frontend/dist
	go test -short ./...

lint: | frontend/dist
	go tool golangci-lint run ./...

fmt:
	gofmt -w .

vet: | frontend/dist
	go vet ./...

# linux-deps installs the Wails v3 cgo build dependencies (Linux only):
# GTK4 + WebKitGTK 6.0 — Ubuntu 24.04+/Debian 13+. Older distros that ship
# only WebKit2GTK 4.1 must build with `-tags gtk3` (supported through
# v3.0.x). One definition shared by ci.yml and lint.yml.
linux-deps:
	sudo apt-get update
	sudo apt-get install -y \
		build-essential \
		pkg-config \
		libgtk-4-dev \
		libwebkitgtk-6.0-dev

# package produces the platform's release payload: darwin builds the .app
# bundle (ad-hoc codesigned); on linux and windows the built binary itself
# is the payload, so build is enough.
package: build
ifeq ($(shell go env GOOS),darwin)
	wails3 package
endif

artifact-name:
	@case "$$(go env GOOS)" in \
	linux) echo "$(APP)-linux-$$(go env GOARCH)" ;; \
	darwin) echo "$(APP)-darwin-$$(go env GOARCH).zip" ;; \
	windows) echo "$(APP)-windows-$$(go env GOARCH).exe" ;; \
	*) echo "unsupported GOOS $$(go env GOOS)" >&2; exit 1 ;; \
	esac

# artifact produces the release asset the in-app updater downloads for this
# platform. Names must contain GOOS+GOARCH (the GitHub provider's
# DefaultAssetMatcher picks by substring) and the macOS zip must hold the
# .app as its sole top-level entry (the updater rejects multi-entry
# archives). The release skill adds a SHA256SUMS sidecar over all assets.
artifact: package
	@set -eu; \
	name="$$($(MAKE) -s artifact-name)"; \
	case "$$(go env GOOS)" in \
	linux) cp bin/$(APP) "$$name" ;; \
	windows) cp bin/$(APP).exe "$$name" ;; \
	darwin) (cd bin && zip -ry "../../$$name" $(APP).app) ;; \
	esac; \
	echo "built $$name"

clean:
	rm -rf bin .task frontend/dist frontend/bindings \
	  $(APP)-linux-* $(APP)-darwin-*.zip $(APP)-windows-*.exe.zip SHA256SUMS
