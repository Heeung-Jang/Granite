#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Granite"
EXECUTABLE_NAME="Granite"
BUNDLE_IDENTIFIER="com.codex.granite"
APP_VERSION="0.4.15"
APP_BUILD="19"
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

supports_foundation_models_sdk() {
  local developer_dir="${1:-}"
  if [[ -n "${developer_dir}" ]]; then
    printf 'import FoundationModels\n' | DEVELOPER_DIR="${developer_dir}" swiftc -typecheck - >/dev/null 2>&1
  else
    printf 'import FoundationModels\n' | swiftc -typecheck - >/dev/null 2>&1
  fi
}

select_foundation_models_sdk() {
  local xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"
  if [[ -n "${GRANITE_DEVELOPER_DIR:-}" ]]; then
    export DEVELOPER_DIR="${GRANITE_DEVELOPER_DIR}"
    echo "Using developer dir from GRANITE_DEVELOPER_DIR: ${DEVELOPER_DIR}"
    return
  fi
  if supports_foundation_models_sdk ""; then
    return
  fi
  if [[ -d "${xcode_developer_dir}" ]] && supports_foundation_models_sdk "${xcode_developer_dir}"; then
    export DEVELOPER_DIR="${xcode_developer_dir}"
    echo "Using FoundationModels-capable developer dir: ${DEVELOPER_DIR}"
  fi
}

select_foundation_models_sdk

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
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
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
run_packaged_probe() {
  local label="$1"
  shift
  echo "  - ${label}" >&2
  "${MACOS_DIR}/${EXECUTABLE_NAME}" "$@"
}

run_packaged_probe "smoke-test" --smoke-test
run_packaged_probe "engine-smoke-test" --engine-smoke-test
run_packaged_probe "telemetry-smoke-test" --telemetry-smoke-test
run_packaged_probe "live-preview-probe" --live-preview-probe >/dev/null
run_packaged_probe "live-preview-style-probe" --live-preview-style-probe >/dev/null
run_packaged_probe "live-preview-syntax-probe" --live-preview-syntax-probe >/dev/null
run_packaged_probe "workspace-tabs-probe" --workspace-tabs-probe >/dev/null
run_packaged_probe "startup-vault-restore-probe" --startup-vault-restore-probe >/dev/null
run_packaged_probe "file-tree-actions-probe" --file-tree-actions-probe >/dev/null
run_packaged_probe "auto-index-refresh-probe" --auto-index-refresh-probe >/dev/null
run_packaged_probe "vault-open-freshness-probe" --vault-open-freshness-probe >/dev/null
run_packaged_probe "inspector-indexing-state-probe" --inspector-indexing-state-probe >/dev/null
run_packaged_probe "workspace-pane-layout-probe" --workspace-pane-layout-probe >/dev/null
run_packaged_probe "app-content-zoom-probe" --app-content-zoom-probe >/dev/null
run_packaged_probe "summary-panel-probe" --summary-panel-probe >/dev/null
run_packaged_probe "foundation-models-smoke-probe" --foundation-models-smoke-probe >/dev/null

echo "Packaged app: ${APP_DIR}"
