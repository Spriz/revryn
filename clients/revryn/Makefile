# Build/test targets for the isolated revryn Go CLI + MCP companion module
# (SPEC §12.2.3). Invoke from this directory as: make <target>

GO      ?= go
BIN_DIR ?= bin
VERSION ?= 0.1.0-dev
LDFLAGS  = -s -w -X github.com/spriz/revryn/clients/revryn/internal/commands.Version=$(VERSION)

.PHONY: all build test vet lint fmt-check clean

all: vet test build

## build: static revryn binary (CGO disabled) into $(BIN_DIR)/
build:
	CGO_ENABLED=0 $(GO) build -trimpath -ldflags "$(LDFLAGS)" -o $(BIN_DIR)/revryn ./cmd/revryn

## test: unit tests (deterministic; live smoke only runs when BILLING_URL is set)
test:
	$(GO) test ./...

## vet: static analysis
vet:
	$(GO) vet ./...

## fmt-check: fail when Go sources are not gofmt-clean
fmt-check:
	@out="$$(gofmt -l cmd internal)"; if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

## lint: vet + gofmt check (golangci-lint hook can be added when adopted)
lint: vet fmt-check

clean:
	rm -rf $(BIN_DIR)
