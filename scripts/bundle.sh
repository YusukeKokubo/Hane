#!/bin/sh
# リリースビルドして build/Browser.app にまとめ、Ad-hoc署名する。
# 操作用コマンドは build/browserctl に置く。
# 使い方: scripts/bundle.sh [--run]
set -eu

cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Browser.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Browser" "$APP/Contents/MacOS/Browser"
cp "$BIN_DIR/browserctl" build/browserctl
cp Support/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
echo "作成: $APP, build/browserctl"

if [ "${1:-}" = "--run" ]; then
    open "$APP"
fi
