.PHONY: dev reset-permissions build test

dev:
	sh apps/macos/Scripts/dev.sh

reset-permissions:
	sh apps/macos/Scripts/dev.sh --reset-permissions

build:
	sh apps/macos/Scripts/build-app.sh

test:
	cd apps/web && npm test
	cd packages/meeting-core && swift test
	cd packages/meeting-analysis && swift test
	cd apps/macos && swift test
