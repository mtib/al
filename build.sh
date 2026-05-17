#!/usr/bin/env bash
# Build Al and wrap it into a proper .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="Al"
APP_DIR="build/${APP_NAME}.app"

./tools/download-sherpa.sh

# Guard: ensure sherpa libs exist (catches stale sentinel + partial download)
SHERPA_LIB="build/sherpa-prefix/lib/libsherpa-onnx-c-api.dylib"
[[ -f "${SHERPA_LIB}" ]] || { echo "✗ sherpa libs missing — run: tools/download-sherpa.sh --force"; exit 1; }

echo "→ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
mkdir -p "${APP_DIR}/Contents/Frameworks"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

# Copy sherpa-onnx runtime dylibs (real files only; skip unversioned stubs and symlinks)
find build/sherpa-prefix/lib -maxdepth 1 -name "*.dylib" ! -type l \
    ! -name "libonnxruntime.dylib" \
    | xargs -I{} cp {} "${APP_DIR}/Contents/Frameworks/"

# Patch rpath so the binary finds Frameworks at runtime
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${APP_DIR}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

# Bundle sherpa models
cp -r build/sherpa-models "${APP_DIR}/Contents/Resources/sherpa-models"

if ./tools/make-icon.sh build/icon 2>/dev/null; then
    cp build/icon/icon.icns "${APP_DIR}/Contents/Resources/icon.icns"
fi

# Reuse LiveTranslate's signing identity env var.
# TCC grants are keyed on (cert identity, bundle ID); Al's bundle ID
# (local.mtib.al) is distinct from LiveTranslate's, so each app gets
# its own grants even when signed with the same cert.
SIGN_IDENTITY="${LIVETRANSLATE_SIGN_IDENTITY:--}"
codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    echo "  signed with identity: ${SIGN_IDENTITY}"
fi

echo "✓ built ${APP_DIR}"
echo "  run with: open ${APP_DIR}"
