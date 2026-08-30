.PHONY: build test app install uninstall run clean

build:
	swift build

test:
	swift test

app:
	./scripts/bundle.sh

install: app
	@pkill -x StatusApps 2>/dev/null || true
	rm -rf /Applications/StatusApps.app
	cp -R StatusApps.app /Applications/
	open /Applications/StatusApps.app
	@echo "Instalada. Buscá ⇅ en la barra de menú."

uninstall:
	@pkill -x StatusApps 2>/dev/null || true
	rm -rf /Applications/StatusApps.app
	rm -rf "$(HOME)/Library/Application Support/StatusApps"

run: app
	@pkill -x StatusApps 2>/dev/null || true
	open StatusApps.app

clean:
	swift package clean
	rm -rf .build StatusApps.app
