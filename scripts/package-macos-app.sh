#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Granite"
EXECUTABLE_NAME="Granite"
BUNDLE_IDENTIFIER="com.codex.granite"
ICON_NAME="GraniteAppIcon"
ICON_SOURCE="${ROOT_DIR}/assets/${ICON_NAME}.png"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
LEGACY_APP_DIR="${DIST_DIR}/NativeMarkdown.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
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
if [[ "${LEGACY_APP_DIR}" != "${APP_DIR}" ]]; then
  rm -rf "${LEGACY_APP_DIR}"
fi
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}"

cp "${ROOT_DIR}/mac-app/.build/release/${EXECUTABLE_NAME}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
cp "${ROOT_DIR}/vault-engine/target/release/libvault_engine.dylib" "${FRAMEWORKS_DIR}/libvault_engine.dylib"
chmod 755 "${MACOS_DIR}/${EXECUTABLE_NAME}"

if [[ ! -f "${ICON_SOURCE}" ]]; then
  echo "Missing app icon source: ${ICON_SOURCE}" >&2
  exit 1
fi

ICON_WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${ICON_WORK_DIR}"' EXIT
ICONSET_DIR="${ICON_WORK_DIR}/${ICON_NAME}.iconset"
mkdir -p "${ICONSET_DIR}"
sips -z 16 16 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
sips -z 1024 1024 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/${ICON_NAME}.icns"

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
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>${ICON_NAME}</string>
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
"${MACOS_DIR}/${EXECUTABLE_NAME}" --workspace-tabs-probe >/dev/null

echo "Packaged app: ${APP_DIR}"
