#!/bin/sh
# Builds and runs the tests: Tests/main.swift compiled together with the app's non-view sources.
# The network is stubbed (no request reaches Alpaca or Hyperliquid) and the app's saved data and settings
# are never touched. Exits with 0 only when every check passes.
# usage: Tests/run.sh   (from any folder)
set -e
cd "$(dirname "$0")/.."

# Use Xcode's toolchain when the active developer directory is the Command Line Tools.
if [ -z "$DEVELOPER_DIR" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

xcrun swiftc -swift-version 6 -target "$(uname -m)-apple-macos15.0" \
    OptionValue/Pricing.swift OptionValue/Models.swift OptionValue/AlpacaClient.swift \
    OptionValue/Hyperliquid.swift OptionValue/MarketData.swift OptionValue/Theme.swift \
    OptionValue/DemoData.swift Tests/main.swift -o "$build/OptionValueTests"
"$build/OptionValueTests"
