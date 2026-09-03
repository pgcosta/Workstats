#!/bin/zsh
set -e
APP_NAME="WorkStats"
BUNDLE_ID="com.workstats.app"
BUILD_DIR=".build/release"
APP_DIR="$APP_NAME.app/Contents/MacOS"
RES_DIR="$APP_NAME.app/Contents/Resources"

swift build -c release
rm -rf "$APP_NAME.app"
mkdir -p "$APP_DIR" "$RES_DIR"
cp "$BUILD_DIR/workstats" "$APP_DIR/$APP_NAME"
cp Info.plist "$APP_NAME.app/Contents/Info.plist"
echo "Built $APP_NAME.app — open with: open $APP_NAME.app"
