.PHONY: build app run test clean

APP_NAME := AllTheThings
APP_DIR := build/$(APP_NAME).app

build:
	swift build

app:
	swift build -c release
	@BIN_PATH=$$(swift build -c release --show-bin-path); \
	rm -rf "$(APP_DIR)"; \
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"; \
	cp "$$BIN_PATH/$(APP_NAME)" "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"; \
	cp "Resources/Info.plist" "$(APP_DIR)/Contents/Info.plist"; \
	chmod +x "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"; \
	echo "Built $(APP_DIR)"

run: app
	open "$(APP_DIR)"

test:
	swift test

clean:
	rm -rf .build build
