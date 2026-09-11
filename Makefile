export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

PROJECT := Codenotch.xcodeproj
SCHEME  := Codenotch
DEST    := platform=macOS,arch=arm64

# Debug ad-hoc signs itself when the maintainer's Developer ID certificate
# isn't in the keychain, which is every machine but the maintainer's — so a
# contributor can `make build`/`make test`/`make run` with no Apple account at
# all, per CONTRIBUTING.md. On the maintainer's own machine this is empty and
# changes nothing: project.yml's stable identity is what keeps a keychain
# "Always Allow" grant alive across rebuilds, and forcing ad-hoc there would
# throw that away and bring the prompt back on every `make run`.
ifeq (,$(shell security find-identity -v -p codesigning 2>/dev/null | grep -c "Developer ID Application"))
DEV_SIGN := CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic
endif

.PHONY: gen build test run clean

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug $(DEV_SIGN) build

test: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug $(DEV_SIGN) test

run: build
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/Codenotch.app; \
	pkill -x Codenotch || true; \
	open "$$APP"

clean:
	rm -rf build DerivedData $(PROJECT)

# --- Release -----------------------------------------------------------------
# Produces a signed, notarized .dmg. Run `make release` for the whole thing,
# or the steps one at a time while something is going wrong.
#
# One-time setup, which needs a password and so cannot be scripted here:
#
#   xcrun notarytool store-credentials Codenotch \
#       --apple-id <your-apple-id> --team-id B4932KX535 --password <app-specific-password>
#
# The app-specific password comes from appleid.apple.com → Sign-In and Security
# → App-Specific Passwords. Not your Apple ID password. Without it Apple will
# not issue a ticket — there is no supported path that skips this, in Xcode or
# out of it. Xcode's Organizer can notarize the .app with its own login, but a
# .dmg only ever goes through `notarytool`.

RELEASE_DIR := build/release
APP_NAME    := Codenotch
# The label of the stored notarytool credential in the login keychain (see the
# one-time setup above). Nothing to do with the app's name.
NOTARY_PROFILE := Codenotch
DMG := $(RELEASE_DIR)/$(APP_NAME).dmg

.PHONY: archive dmg notarize release verify-release

# Release configuration, exported with the Developer ID identity. `xcodebuild
# archive` + `-exportArchive` rather than a plain build: it re-signs the bundle
# as a distributable, which a Debug build is not.
archive: gen
	rm -rf $(RELEASE_DIR)
	mkdir -p $(RELEASE_DIR)
	@# Spotlight indexes build output as installed applications, so every
	@# release leaves extra "Codenotch" entries in app search next to the
	@# real one in /Applications. This stops the whole tree being indexed.
	@touch build/.metadata_never_index
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Release -archivePath $(RELEASE_DIR)/$(APP_NAME).xcarchive archive
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>method</key><string>developer-id</string>' \
		'<key>teamID</key><string>B4932KX535</string>' \
		'<key>signingStyle</key><string>manual</string>' \
		'<key>signingCertificate</key><string>Developer ID Application</string>' \
		'</dict></plist>' > $(RELEASE_DIR)/ExportOptions.plist
	xcodebuild -exportArchive \
		-archivePath $(RELEASE_DIR)/$(APP_NAME).xcarchive \
		-exportOptionsPlist $(RELEASE_DIR)/ExportOptions.plist \
		-exportPath $(RELEASE_DIR)

-include Makefile.local

# App Store Connect notarization credentials.
# Override via environment variables or gitignored `Makefile.local`.
ASC_KEY    ?=
ASC_KEY_ID ?=
ASC_ISSUER ?=

# A plain drag-to-Applications disk image. `hdiutil` writes it read-only and
# compressed, which is what notarization expects.
dmg: archive
	rm -f $(DMG)
	rm -rf $(RELEASE_DIR)/stage
	mkdir -p $(RELEASE_DIR)/stage
	cp -R $(RELEASE_DIR)/$(APP_NAME).app $(RELEASE_DIR)/stage/
	ln -s /Applications $(RELEASE_DIR)/stage/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(RELEASE_DIR)/stage \
		-ov -format UDZO $(DMG)
	codesign --force --sign "Developer ID Application" --timestamp $(DMG)
	rm -rf $(RELEASE_DIR)/stage

# Submits and waits. `--wait` blocks until Apple answers, which is usually a
# couple of minutes; on rejection, the log says which binary failed and why.
# Afterwards the ticket is stapled to the dmg, so Gatekeeper passes it offline.
notarize: dmg
	@if [ -z "$(ASC_KEY)" ] || [ -z "$(ASC_KEY_ID)" ] || [ -z "$(ASC_ISSUER)" ]; then \
		echo "Error: ASC_KEY, ASC_KEY_ID, and ASC_ISSUER must be set (via Makefile.local or environment)"; exit 1; \
	fi
	xcrun notarytool submit $(DMG) --key $(ASC_KEY) --key-id $(ASC_KEY_ID) --issuer $(ASC_ISSUER) --wait
	xcrun stapler staple $(DMG)
	xcrun stapler staple $(RELEASE_DIR)/$(APP_NAME).app || true

release: archive dmg notarize verify-release
	@echo "Notarized: $(DMG)"

# What Gatekeeper on a customer's Mac will check. `spctl` accepting the dmg is
# the actual proof that the download will open without a right-click.
verify-release:
	xcrun stapler validate $(DMG)
	mkdir -p $(RELEASE_DIR)/mnt
	hdiutil attach $(DMG) -nobrowse -mountpoint $(RELEASE_DIR)/mnt
	codesign --verify --deep --strict --verbose=2 $(RELEASE_DIR)/mnt/$(APP_NAME).app
	spctl --assess --type execute --verbose=4 $(RELEASE_DIR)/mnt/$(APP_NAME).app
	hdiutil detach $(RELEASE_DIR)/mnt
	spctl --assess --type install --verbose=4 $(DMG)
