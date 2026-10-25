APP_NAME := Karuta
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
# 自己署名証明書の名前を渡すと、再ビルドしても画面収録の許可が維持されます
SIGN_IDENTITY ?= -

.PHONY: app run install clean

app:
	swift build -c release -Xswiftc -Osize
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	strip -x "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"
	@du -sh "$(APP)"

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/

clean:
	rm -rf .build "$(BUILD_DIR)"
