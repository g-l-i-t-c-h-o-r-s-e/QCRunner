#!/usr/bin/env bash
set -euo pipefail

# QCRunner 32/64-bit build script (ARC on x86_64, non-ARC on i386)
# EXAMPLE: ./build.sh --arch universal  --src main.m --comp "/Users/YOU/Documents/screensaver.qtz" --sdk-i386 "/Applications/Xcode_9.4.1.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.13.sdk" 

# --- Defaults ---
APP_NAME="QCRunner"
BUNDLE_ID="com.example.QCRunner"
APP_VERSION="1.0"

SRC_MAIN="main.m"
COMP_QTZ=""
FLAGS_FILE=""
OUTDIR="build"
ARCH="universal"       # i386 | x86_64 | universal
PREFER_32="0"

MIN_MACOS_64="10.9"
MIN_MACOS_32="10.6"

SDK_I386=""            # e.g. /Applications/Xcode_9.4.1.app/.../MacOSX10.13.sdk
SDK_X64=""             # auto from xcrun if empty

usage() {
  cat <<EOF
Usage: $0 [options]
  --name NAME           (default: ${APP_NAME})
  --bundle-id ID        (default: ${BUNDLE_ID})
  --version VER         (default: ${APP_VERSION})
  --src PATH            (default: ${SRC_MAIN})
  --comp PATH           embed as Contents/Resources/Default.qtz
  --flags PATH          copy as Contents/MacOS/QCRunner.flags
  --outdir DIR          (default: ${OUTDIR})
  --arch A              i386 | x86_64 | universal (default: universal)
  --prefer-32           prefer 32-bit on double-click (universal only)
  --min32 VER           (default: ${MIN_MACOS_32})
  --min64 VER           (default: ${MIN_MACOS_64})
  --sdk-i386 PATH       REQUIRED for i386/universal (MacOSX10.13.sdk)
  --sdk-x64  PATH       override SDK for x86_64
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)       APP_NAME="${2:-}"; shift 2 ;;
    --bundle-id)  BUNDLE_ID="${2:-}"; shift 2 ;;
    --version)    APP_VERSION="${2:-}"; shift 2 ;;
    --src)        SRC_MAIN="${2:-}"; shift 2 ;;
    --comp)       COMP_QTZ="${2:-}"; shift 2 ;;
    --flags)      FLAGS_FILE="${2:-}"; shift 2 ;;
    --outdir)     OUTDIR="${2:-}"; shift 2 ;;
    --arch)       ARCH="${2:-}"; shift 2 ;;
    --prefer-32)  PREFER_32="1"; shift 1 ;;
    --min32)      MIN_MACOS_32="${2:-}"; shift 2 ;;
    --min64)      MIN_MACOS_64="${2:-}"; shift 2 ;;
    --sdk-i386)   SDK_I386="${2:-}"; shift 2 ;;
    --sdk-x64)    SDK_X64="${2:-}"; shift 2 ;;
    -h|--help)    usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# --- Checks ---
[[ -f "$SRC_MAIN" ]] || { echo "ERROR: source not found: $SRC_MAIN" >&2; exit 2; }
[[ -z "$COMP_QTZ" || -f "$COMP_QTZ" ]] || { echo "ERROR: .qtz not found: $COMP_QTZ" >&2; exit 2; }
[[ -z "$FLAGS_FILE" || -f "$FLAGS_FILE" ]] || { echo "ERROR: flags not found: $FLAGS_FILE" >&2; exit 2; }

need_i386="0"; [[ "$ARCH" == "i386" || "$ARCH" == "universal" ]] && need_i386="1"
if [[ "$need_i386" == "1" && -z "$SDK_I386" ]]; then
  guess="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.13.sdk"
  [[ -d "$guess" ]] && SDK_I386="$guess" || { echo "ERROR: --sdk-i386 (10.13 SDK) required" >&2; exit 3; }
fi

if [[ -z "$SDK_X64" ]] && command -v xcrun >/dev/null 2>&1; then
  SDK_X64="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
fi

# --- Paths ---
APP_DIR="${OUTDIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"
PLIST="${APP_DIR}/Contents/Info.plist"
BIN="${MACOS_DIR}/${APP_NAME}"
BIN_I386="${OUTDIR}/.${APP_NAME}.i386"
BIN_X64="${OUTDIR}/.${APP_NAME}.x64"

echo "==> Building ${APP_NAME}.app (${ARCH}) in ${OUTDIR}"
rm -rf "$APP_DIR" "$BIN_I386" "$BIN_X64"
mkdir -p "$MACOS_DIR" "$RES_DIR"

write_plist() {
  local arch="$1" prefer32="$2"
  local lsv="${MIN_MACOS_64}"
  [[ "$arch" == "i386" ]] && lsv="${MIN_MACOS_32}"
  [[ "$arch" == "universal" ]] && lsv="$(printf '%s\n%s\n' "$MIN_MACOS_32" "$MIN_MACOS_64" | sort -V | head -n1)"

  local arch_block=""
  if [[ "$arch" == "universal" ]]; then
    if [[ "$prefer32" == "1" ]]; then
      arch_block='<key>LSArchitecturePriority</key><array><string>i386</string><string>x86_64</string></array>'
    else
      arch_block='<key>LSArchitecturePriority</key><array><string>x86_64</string><string>i386</string></array>'
    fi
  else
    arch_block="<key>LSArchitecturePriority</key><array><string>${arch}</string></array>"
  fi

  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>${APP_VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>${lsv}</string>
  <key>NSHighResolutionCapable</key><true/>
  ${arch_block}
</dict></plist>
EOF
}
write_plist "$ARCH" "$PREFER_32"

compile_x64() {
  echo "==> [x86_64] Compiling (ARC ON) ${SRC_MAIN}"
  clang -arch x86_64 -fobjc-arc -mmacosx-version-min="${MIN_MACOS_64}" \
    ${SDK_X64:+-isysroot "$SDK_X64"} \
    -framework Cocoa -framework Quartz -framework IOKit \
    -framework Carbon -framework ApplicationServices \
    -o "$BIN_X64" "$SRC_MAIN"
}

compile_i386() {
  echo "==> [i386] Compiling (ARC OFF) ${SRC_MAIN}"
  clang -arch i386 -mmacosx-version-min="${MIN_MACOS_32}" \
    -isysroot "$SDK_I386" \
    -Wno-deprecated-declarations \
    -framework Cocoa -framework Quartz -framework IOKit \
    -framework Carbon -framework ApplicationServices \
    -o "$BIN_I386" "$SRC_MAIN"
}

case "$ARCH" in
  x86_64) compile_x64; cp -f "$BIN_X64" "$BIN" ;;
  i386)   compile_i386; cp -f "$BIN_I386" "$BIN" ;;
  universal)
    compile_x64
    compile_i386
    echo "==> Lipo merge -> ${BIN}"
    lipo -create -output "$BIN" "$BIN_X64" "$BIN_I386"
    ;;
  *) echo "ERROR: --arch must be i386 | x86_64 | universal" >&2; exit 4 ;;
esac

chmod +x "$BIN"

if [[ -n "$COMP_QTZ" ]]; then
  echo "==> Copying Default.qtz"
  cp -f "$COMP_QTZ" "${RES_DIR}/Default.qtz"
fi

if [[ -n "$FLAGS_FILE" ]]; then
  echo "==> Copying QCRunner.flags"
  cp -f "$FLAGS_FILE" "${MACOS_DIR}/QCRunner.flags"
fi

if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc signing"
  codesign --force --deep --sign - "$APP_DIR" || true
fi

echo
echo "✅ Built: ${APP_DIR}"
case "$ARCH" in
  universal)
    echo "   • Universal binary (i386 + x86_64)"
    [[ "$PREFER_32" == "1" ]] && echo "   • Finder prefers 32-bit (i386)" || echo "   • Finder prefers 64-bit (x86_64)"
    echo "   • Force a specific arch via:"
    echo "       arch -i386   \"${APP_DIR}/Contents/MacOS/${APP_NAME}\" --comp \"/abs/path.qtz\""
    echo "       arch -x86_64 \"${APP_DIR}/Contents/MacOS/${APP_NAME}\" --comp \"/abs/path.qtz\""
    ;;
  i386)   echo "   • Binary: i386 (ARC OFF)";;
  x86_64) echo "   • Binary: x86_64 (ARC ON)";;
esac
[[ -n "$COMP_QTZ" ]] && echo "   • Embedded: Contents/Resources/Default.qtz" || echo "   • No Default.qtz embedded"
[[ -n "$FLAGS_FILE" ]] && echo "   • Copied: Contents/MacOS/QCRunner.flags"
echo
echo "Run by double-clicking the app, or:"
echo "  open \"${APP_DIR}\""
