#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="NativeMarkdown"
EXECUTABLE_NAME="NativeMarkdownApp"
BUNDLE_IDENTIFIER="com.codex.nativemarkdown"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
INFO_PLIST="${CONTENTS_DIR}/Info.plist"

echo "Building Rust engine..."
cargo build --manifest-path "${ROOT_DIR}/vault-engine/Cargo.toml" --release

echo "Building macOS app executable..."
swift build \
  --package-path "${ROOT_DIR}/mac-app" \
  -c release \
  --product "${EXECUTABLE_NAME}"

echo "Creating app bundle..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}"

cp "${ROOT_DIR}/mac-app/.build/release/${EXECUTABLE_NAME}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
cp "${ROOT_DIR}/vault-engine/target/release/libvault_engine.dylib" "${FRAMEWORKS_DIR}/libvault_engine.dylib"
chmod 755 "${MACOS_DIR}/${EXECUTABLE_NAME}"

cat > "${INFO_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_IDENTIFIER}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "${INFO_PLIST}"

echo "Signing app bundle ad hoc..."
codesign --force --sign - --timestamp=none "${FRAMEWORKS_DIR}/libvault_engine.dylib"
codesign --force --sign - --timestamp=none "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

echo "Running packaged smoke tests..."
"${MACOS_DIR}/${EXECUTABLE_NAME}" --smoke-test
"${MACOS_DIR}/${EXECUTABLE_NAME}" --engine-smoke-test
"${MACOS_DIR}/${EXECUTABLE_NAME}" --telemetry-smoke-test
"${MACOS_DIR}/${EXECUTABLE_NAME}" --live-preview-probe >/dev/null

echo "Packaged app: ${APP_DIR}"
