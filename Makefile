# Open WebUI + Ollama QPKG: build, tests and release files.
#
#   make              build build/OpenWebUIOllama_<version>_x86_64.qpkg in Docker
#   make test         lint, pin check, lifecycle test
#   make pin          re-resolve every tag in shared/images.lock
#   make release-files  copy images.lock, LICENSE and NOTICE.md into build/, write SHA256SUMS
#   make clean

BUILDER_IMAGE := openwebui-ollama-qpkg-builder
SHELLCHECK    := koalaman/shellcheck-alpine:stable@sha256:c82fe42504fbc9fc68f15d36638e5ee2324ebb8b94e96a3c4e395bf361c49183
SRC           := $(CURDIR)
SH_FILES      := $(wildcard shared/*.sh shared/lib/*.sh scripts/*.sh tests/*.sh) package_routines

.PHONY: all builder qpkg lint check-pins test test-lifecycle pin release-files clean

all: qpkg

builder:
	docker build -t $(BUILDER_IMAGE) .

qpkg: builder
	docker run --rm -u "$$(id -u):$$(id -g)" -v "$(SRC)":/src -w /src $(BUILDER_IMAGE) \
		qbuild --build-arch x86_64
	@ls -l build/*.qpkg

lint:
	docker run --rm -v "$(SRC)":/mnt -w /mnt $(SHELLCHECK) \
		shellcheck -s sh -x -P SCRIPTDIR -e SC1091 $(SH_FILES) tests/stubs/*

check-pins:
	sh scripts/check-pins.sh
	sh scripts/check-ci-pins.sh

test-lifecycle:
	sh tests/lifecycle.sh

test: lint check-pins test-lifecycle

pin:
	sh scripts/pin-images.sh

release-files:
	cp shared/images.lock LICENSE NOTICE.md build/
	cd build && sha256sum *.qpkg images.lock LICENSE NOTICE.md > SHA256SUMS && cat SHA256SUMS

clean:
	rm -rf build
