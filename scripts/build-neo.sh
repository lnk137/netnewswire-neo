#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Upstream does not distribute its private OAuth/Reader View service credentials.
secret_source=Modules/Secrets/Sources/Secrets/SecretKey.swift
if [ ! -f "$secret_source" ]; then
cat > "$secret_source" <<'SWIFT'
public struct SecretKey {
 public static let mercuryClientID = ""
 public static let mercuryClientSecret = ""
 public static let feedlyClientID = ""
 public static let feedlyClientSecret = ""
 public static let inoreaderAppID = ""
 public static let inoreaderAppKey = ""
}
SWIFT
fi
xcodebuild -project NetNewsWire.xcodeproj -scheme NetNewsWire -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build-local \
  CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= ORGANIZATION_IDENTIFIER=local.lnk137 \
  DEVELOPER_ENTITLEMENTS=-dev build
app='.build-local/Build/Products/Debug/NetNewsWire Neo.app'
# Keep the app-specific certificate stable so updates retain Keychain access.
signing_identity=$(bash scripts/ensure-local-signing.sh)
codesign --force --deep --sign "$signing_identity" --timestamp=none "$app"
codesign --verify --deep --strict "$app"
printf '\nBuilt: %s\n' "$PWD/$app"
