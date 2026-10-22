SHELL := /bin/bash
BIN := .build/release/dsh-cua
SWIFT ?= swift

.PHONY: all build test mcp-test lint install-skill clean

all: build

build:
	$(SWIFT) build -c release

# The assertions live in the binary (`dsh-cua selftest`) rather than in an XCTest target,
# because this package must build on machines that have only the Command Line Tools —
# where the `XCTest` module does not exist and `swift test` cannot compile at all.
test: build
	$(BIN) selftest --json

mcp-test:
	node --check mcp/server.mjs
	node mcp/test-server.mjs

lint:
	$(SWIFT) build -c release
	node --check mcp/server.mjs

install-skill: build
	bash scripts/install-skill.sh

clean:
	$(SWIFT) package clean
	rm -rf .build
