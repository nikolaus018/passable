#!/bin/sh
# Builds Passable for iPhone, installs it on a paired iPhone over Wi-Fi/USB, launches it,
# and (optionally) sends it the sample set from this Mac.
#
#   Tools/install-on-iphone.sh [device name or UDID] [--send]
#
# Needs an Apple ID signed in under Xcode > Settings > Accounts (so Xcode can make the
# signing profile), the phone unlocked, and Developer Mode on.
set -e
cd "$(dirname "$0")/.."
DEVICE="${1:-privat}"
BUNDLE_ID=com.nikolausmarek.PassableIos
DERIVED="${TMPDIR:-/tmp}/passableios-device-build"

xcodegen generate >/dev/null
xcodebuild -project PassableIos.xcodeproj -scheme PassableIos \
    -destination "platform=iOS,name=$DEVICE" -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates build | tail -3

APP="$DERIVED/Build/Products/Debug-iphoneos/PassableIos.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
echo "Installed and launched on $DEVICE."

if [ "$2" = "--send" ]; then
    swiftc -O Tools/SendMix/main.swift ../Passable/Model/PassableMix.swift \
        ../Passable/Library/PhoneLink.swift -o "$DERIVED/send-mix"
    echo "Keep the app open on the phone and tap Accept when it asks."
    "$DERIVED/send-mix" "Samples/Sample Set.passablemix"
fi
