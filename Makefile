APP_NAME := Karuta
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
# 自己署名証明書の名前を渡すと、再ビルドしても画面収録の許可が維持されます
SIGN_IDENTITY ?= -
# 未指定なら Support/Info.plist のバージョンを使います（例: make dmg VERSION=0.2.0）
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
DMG := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg

.PHONY: app dmg icon run install clean

app:
	swift build -c release -Xswiftc -Osize
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	strip -x "$(APP)/Contents/MacOS/$(APP_NAME)"
	mkdir -p "$(APP)/Contents/Resources"
	cp Support/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"
	@du -sh "$(APP)"

dmg: app
	rm -rf "$(BUILD_DIR)/dmg" "$(DMG)"
	mkdir -p "$(BUILD_DIR)/dmg"
	cp -R "$(APP)" "$(BUILD_DIR)/dmg/"
	ln -s /Applications "$(BUILD_DIR)/dmg/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(BUILD_DIR)/dmg" -format ULFO -ov "$(DMG)"
	rm -rf "$(BUILD_DIR)/dmg"
	@if [ "$(SIGN_IDENTITY)" != "-" ]; then codesign --force --sign "$(SIGN_IDENTITY)" "$(DMG)"; fi
	@du -sh "$(DMG)"

# Support/AppIcon.svg を変更したら実行して AppIcon.icns をコミットする
icon:
	scripts/make-icns.sh

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/

clean:
	rm -rf .build "$(BUILD_DIR)"
