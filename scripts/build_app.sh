#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="VitaPet"
BIN_NAME="VitaPetApp"
BUNDLE_ID="com.vitapet.VitaPet"
VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0-dev")"
VERSION="${VERSION#v}"

ARCHS_ENV="${ARCHS:-}"
if [ -n "${ARCHS_ENV}" ]; then
  # shellcheck disable=SC2206
  ARCH_LIST=(${ARCHS_ENV})
else
  ARCH_LIST=("$(uname -m)")
fi

OUT_DIR="dist"
APP_BASENAME="${APP_NAME}.app"
APP_DIR="${OUT_DIR}/${APP_BASENAME}"

BUILD_ARGS=(-c release)
for arch in "${ARCH_LIST[@]}"; do
  BUILD_ARGS+=(--arch "$arch")
done

echo "==> swift build ${BUILD_ARGS[*]}"
swift build "${BUILD_ARGS[@]}"

BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_DIR}/${BIN_NAME}" "${APP_DIR}/Contents/MacOS/${BIN_NAME}"

# SwiftPM's generated Bundle.module accessor looks for resource bundles at
# Bundle.main.bundleURL — for a .app that's the .app root, not Contents/Resources.
# Place bundles at both locations: the accessor path (app root) and the standard
# Contents/Resources for discoverability.
for bundle in "${BIN_DIR}"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "${APP_DIR}/"
  cp -R "$bundle" "${APP_DIR}/Contents/Resources/"
done

ICON_SRC="App/Resources/AppIcon.icns"
echo "==> Generating AppIcon.icns"
swift scripts/generate_icon.swift "🐱" "${ICON_SRC}"
cp "${ICON_SRC}" "${APP_DIR}/Contents/Resources/AppIcon.icns"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${BIN_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
  <key>NSLocationUsageDescription</key>
  <string>VitaPet uses your location to fetch local weather for pet reactions.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>VitaPet uses your location to fetch local weather for pet reactions.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "==> Built ${APP_DIR}"

# Default: copy into /Applications so local builds match “install the app” workflow.
# Set INSTALL=0 to only produce dist/ (e.g. CI, or you’ll copy the .app yourself).
if [ "${INSTALL:-1}" = "1" ]; then
  DEST="/Applications/${APP_BASENAME}"
  echo "==> Installing to ${DEST}"
  rm -rf "${DEST}"
  cp -R "${APP_DIR}" "${DEST}"
  echo "==> Installed. Launch via Applications or:"
  echo "    open \"${DEST}\""
  LEGACY="/Applications/${APP_NAME}-arm64.app"
  if [ -d "$LEGACY" ]; then
    echo "==> 旧包仍可手动删除: rm -rf \"${LEGACY}\""
  fi
else
  echo "==> Skipped /Applications (INSTALL=0). App bundle: ${APP_DIR}"
fi
