#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexTokenOverlay"
PRODUCT_NAME="CodexTokenOverlayMac"
BUNDLE_ID="io.github.soleillevant0125.CodexTokenOverlay"
MIN_SYSTEM_VERSION="14.0"
ARCH="$(uname -m)"
CONFIGURATION="release"
VERSION="0.2.1"
OUTPUT_DIR=""

usage() {
  echo "usage: $0 [--arch arm64|x86_64] [--configuration debug|release] [--version 0.2.1] [--output directory]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      ARCH="${2:-}"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  echo "unsupported architecture: $ARCH" >&2
  exit 2
fi

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  echo "unsupported configuration: $CONFIGURATION" >&2
  exit 2
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "invalid version: $VERSION" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
MACOS_DIR="$ROOT_DIR/macos"
ARTIFACTS_ROOT="$ROOT_DIR/artifacts"
DIST_ROOT="$ROOT_DIR/dist"
RUNNER_TEMP_VALUE="${RUNNER_TEMP:-}"
TMPDIR_VALUE="${TMPDIR:-}"
mkdir -p "$ARTIFACTS_ROOT" "$DIST_ROOT"
if [[ -L "$ARTIFACTS_ROOT" || -L "$DIST_ROOT" ]]; then
  echo "artifacts and dist must not be symbolic links" >&2
  exit 2
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT_DIR/artifacts/macos-$ARCH"
elif [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR"
fi

# 删除输出前先做词法和真实路径双重校验，避免 --output 误伤其他目录。
OUTPUT_BASENAME="$(basename "$OUTPUT_DIR")"
if [[ -z "$OUTPUT_BASENAME" || "$OUTPUT_BASENAME" == "." || "$OUTPUT_BASENAME" == ".." ]]; then
  echo "refusing unsafe output directory: $OUTPUT_DIR" >&2
  exit 2
fi
case "/$OUTPUT_DIR/" in
  *"/../"*|*"/./"*)
    echo "output directory must not contain . or .. components: $OUTPUT_DIR" >&2
    exit 2
    ;;
esac

ALLOWED_INPUT_ROOTS=("$ARTIFACTS_ROOT" "$DIST_ROOT")
if [[ -n "$RUNNER_TEMP_VALUE" && -d "$RUNNER_TEMP_VALUE" ]]; then
  ALLOWED_INPUT_ROOTS+=("${RUNNER_TEMP_VALUE%/}")
fi
if [[ -n "$TMPDIR_VALUE" && -d "$TMPDIR_VALUE" ]]; then
  ALLOWED_INPUT_ROOTS+=("${TMPDIR_VALUE%/}")
fi
if [[ -d /tmp ]]; then
  ALLOWED_INPUT_ROOTS+=("/tmp")
fi

LEXICALLY_ALLOWED=false
for allowed_root in "${ALLOWED_INPUT_ROOTS[@]}"; do
  case "$OUTPUT_DIR" in
    "$allowed_root"/*)
      LEXICALLY_ALLOWED=true
      break
      ;;
  esac
done
if [[ "$LEXICALLY_ALLOWED" != true ]]; then
  echo "output must be below repository artifacts/dist or a temporary directory: $OUTPUT_DIR" >&2
  exit 2
fi

OUTPUT_PARENT="$(dirname "$OUTPUT_DIR")"
mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd -P)"
OUTPUT_DIR="$OUTPUT_PARENT/$OUTPUT_BASENAME"

ALLOWED_REAL_ROOTS=(
  "$(cd "$ARTIFACTS_ROOT" && pwd -P)"
  "$(cd "$DIST_ROOT" && pwd -P)"
)
if [[ -n "$RUNNER_TEMP_VALUE" && -d "$RUNNER_TEMP_VALUE" ]]; then
  ALLOWED_REAL_ROOTS+=("$(cd "$RUNNER_TEMP_VALUE" && pwd -P)")
fi
if [[ -n "$TMPDIR_VALUE" && -d "$TMPDIR_VALUE" ]]; then
  ALLOWED_REAL_ROOTS+=("$(cd "$TMPDIR_VALUE" && pwd -P)")
fi
if [[ -d /tmp ]]; then
  ALLOWED_REAL_ROOTS+=("$(cd /tmp && pwd -P)")
fi

REALLY_ALLOWED=false
for allowed_root in "${ALLOWED_REAL_ROOTS[@]}"; do
  case "$OUTPUT_DIR" in
    "$allowed_root"/*)
      REALLY_ALLOWED=true
      break
      ;;
  esac
done
if [[ "$REALLY_ALLOWED" != true ]]; then
  echo "resolved output escapes the allowed roots: $OUTPUT_DIR" >&2
  exit 2
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

swift build \
  --package-path "$MACOS_DIR" \
  --configuration "$CONFIGURATION" \
  --arch "$ARCH" \
  --product "$PRODUCT_NAME"

BIN_DIR="$(swift build \
  --package-path "$MACOS_DIR" \
  --configuration "$CONFIGURATION" \
  --arch "$ARCH" \
  --show-bin-path)"
BUILD_BINARY="$BIN_DIR/$PRODUCT_NAME"

if [[ ! -x "$BUILD_BINARY" ]]; then
  echo "missing executable: $BUILD_BINARY" >&2
  exit 1
fi

APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_CONTENTS="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_BINARY="$MACOS_CONTENTS/$PRODUCT_NAME"
INFO_PLIST="$CONTENTS_DIR/Info.plist"

mkdir -p "$MACOS_CONTENTS" "$RESOURCES_DIR"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/README.md" "$RESOURCES_DIR/README.md"
cp "$ROOT_DIR/README.zh-CN.md" "$RESOURCES_DIR/README.zh-CN.md"
cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"

# CFBundleShortVersionString 只使用点分数字，开发后缀不写入 plist。
BUNDLE_VERSION="${VERSION%%-*}"
cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Codex Token Overlay</string>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Codex Token Overlay</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$BUNDLE_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUNDLE_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST"

# 无 Developer ID 时使用 ad-hoc 签名保证包内代码完整性；它不等同于公证。
codesign --force --sign - --timestamp=none "$APP_BINARY"
codesign --force --sign - --timestamp=none "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

BUILT_ARCHS="$(lipo -archs "$APP_BINARY")"
if [[ " $BUILT_ARCHS " != *" $ARCH "* ]]; then
  echo "unexpected executable architecture: $BUILT_ARCHS (expected $ARCH)" >&2
  exit 1
fi

file "$APP_BINARY"
echo "$APP_BUNDLE"
