#!/bin/sh
set -e

if [ "$CI_XCODEBUILD_ACTION" != "archive" ]; then
  exit 0
fi

if [ -z "$CI_ARCHIVE_PATH" ]; then
  echo "ci_post_xcodebuild: no CI_ARCHIVE_PATH, skipping"
  exit 0
fi

echo "ci_post_xcodebuild: uploading $CI_ARCHIVE_PATH to TestFlight"

KEY_DIR=$(mktemp -d)
KEY_ID="9AHH974Y96"
ISSUER_ID="69a6de87-5a54-47e3-e053-5b8c7c11a4d1"
KEY_PATH="$KEY_DIR/AuthKey_${KEY_ID}.p8"

cat > "$KEY_PATH" << 'KEY'
-----BEGIN PRIVATE KEY-----
MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgwan1YGfKkP6FalFk
kg2MV0aeervARKh3ftOu2ZtuVy+gCgYIKoZIzj0DAQehRANCAAQg7uAv37S8odKf
zrM0sq5HHY75HQvDABqdw8/TjDKjvU/NKMYOqT7M0a7g0PpeAC0WnrZtQkKpruYj
AgxZTNLZ
-----END PRIVATE KEY-----
KEY

EXPORT_DIR=$(mktemp -d)
EXPORT_OPTIONS="$EXPORT_DIR/ExportOptions.plist"

cat > "$EXPORT_OPTIONS" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>6GQ6BYE2DM</string>
    <key>destination</key>
    <string>upload</string>
    <key>uploadSymbols</key>
    <true/>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$CI_ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  -allowProvisioningUpdates

echo "ci_post_xcodebuild: upload complete"
