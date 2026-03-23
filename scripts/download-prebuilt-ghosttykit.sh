#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -n "${GHOSTTY_SHA:-}" ]; then
  GHOSTTY_SHA="$GHOSTTY_SHA"
else
  if [ ! -d "$REPO_ROOT/ghostty" ] || ! git -C "$REPO_ROOT/ghostty" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Missing ghostty submodule. Run ./scripts/setup.sh or git submodule update --init --recursive first." >&2
    exit 1
  fi
  GHOSTTY_SHA="$(git -C "$REPO_ROOT/ghostty" rev-parse HEAD)"
fi

TAG="xcframework-$GHOSTTY_SHA"
ARCHIVE_NAME="${GHOSTTYKIT_ARCHIVE_NAME:-GhosttyKit.xcframework.tar.gz}"
OUTPUT_DIR="${GHOSTTYKIT_OUTPUT_DIR:-GhosttyKit.xcframework}"
CHECKSUMS_FILE="${GHOSTTYKIT_CHECKSUMS_FILE:-$SCRIPT_DIR/ghosttykit-checksums.txt}"
DOWNLOAD_URL="${GHOSTTYKIT_URL:-https://github.com/atlascodesai/cmux-atlas/releases/download/$TAG/$ARCHIVE_NAME}"
DOWNLOAD_RETRIES="${GHOSTTYKIT_DOWNLOAD_RETRIES:-30}"
DOWNLOAD_RETRY_DELAY="${GHOSTTYKIT_DOWNLOAD_RETRY_DELAY:-20}"

if [ ! -f "$CHECKSUMS_FILE" ]; then
  echo "Missing checksum file: $CHECKSUMS_FILE" >&2
  exit 1
fi

EXPECTED_SHA256="$(
  awk -v sha="$GHOSTTY_SHA" '
    $1 == sha {
      print $2
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$CHECKSUMS_FILE" || true
)"

if [ -z "$EXPECTED_SHA256" ]; then
  echo "No pinned checksum for ghostty $GHOSTTY_SHA — building from source"
  BUILD_FROM_SOURCE=1
else
  BUILD_FROM_SOURCE=0
fi

if [ "$BUILD_FROM_SOURCE" -eq 0 ]; then
  echo "Downloading $ARCHIVE_NAME for ghostty $GHOSTTY_SHA"
  if curl --fail --show-error --location \
    --retry "$DOWNLOAD_RETRIES" \
    --retry-delay "$DOWNLOAD_RETRY_DELAY" \
    --retry-all-errors \
    -o "$ARCHIVE_NAME" \
    "$DOWNLOAD_URL"; then

    ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_NAME" | awk '{print $1}')"
    if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
      echo "$ARCHIVE_NAME checksum mismatch" >&2
      echo "Expected: $EXPECTED_SHA256" >&2
      echo "Actual:   $ACTUAL_SHA256" >&2
      exit 1
    fi

    rm -rf "$OUTPUT_DIR"
    tar xzf "$ARCHIVE_NAME"
    rm "$ARCHIVE_NAME"
    test -d "$OUTPUT_DIR"
    echo "Verified and extracted $OUTPUT_DIR"
  else
    echo "Download failed — falling back to build from source"
    BUILD_FROM_SOURCE=1
  fi
fi

if [ "$BUILD_FROM_SOURCE" -eq 1 ]; then
  # Ensure homebrew tools (msgfmt/gettext) and local zig are in PATH
  if [ -d /opt/homebrew/bin ]; then
    export PATH="/opt/homebrew/bin:$PATH"
  fi
  if [ -d "$HOME/.local/bin" ]; then
    export PATH="$HOME/.local/bin:$PATH"
  fi

  echo "Building GhosttyKit.xcframework from source..."
  if ! command -v zig >/dev/null 2>&1; then
    echo "zig not found — installing zig 0.15.2..."
    ZIG_REQUIRED="0.15.2"
    ARCH="$(uname -m)"
    if [ "$ARCH" = "arm64" ]; then ARCH="aarch64"; fi
    curl -fSL "https://ziglang.org/download/${ZIG_REQUIRED}/zig-${ARCH}-macos-${ZIG_REQUIRED}.tar.xz" -o /tmp/zig.tar.xz
    tar xf /tmp/zig.tar.xz -C /tmp
    export PATH="/tmp/zig-${ARCH}-macos-${ZIG_REQUIRED}:$PATH"
    rm /tmp/zig.tar.xz
    zig version
  fi

  cd "$REPO_ROOT/ghostty"
  rm -rf .zig-cache zig-out

  # Run zig build with output captured to see errors
  set +e
  zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=universal -Doptimize=ReleaseFast 2>&1
  ZIG_RC=$?
  set -e

  if [ "$ZIG_RC" -ne 0 ]; then
    echo "zig build failed (exit code $ZIG_RC)"
    # Try copying from a previous build if available
    if [ -d "$REPO_ROOT/ghostty/macos/GhosttyKit.xcframework" ]; then
      echo "Copying GhosttyKit.xcframework from previous ghostty build..."
      cd "$REPO_ROOT"
      rm -rf "$OUTPUT_DIR"
      cp -R ghostty/macos/GhosttyKit.xcframework "$OUTPUT_DIR"
    else
      exit 1
    fi
  else
    cd "$REPO_ROOT"
    # zig build puts the xcframework in ghostty/macos/
    if [ ! -d "$OUTPUT_DIR" ] && [ -d "$REPO_ROOT/ghostty/macos/GhosttyKit.xcframework" ]; then
      cp -R "$REPO_ROOT/ghostty/macos/GhosttyKit.xcframework" "$OUTPUT_DIR"
    fi
  fi

  test -d "$OUTPUT_DIR"
  echo "Built $OUTPUT_DIR from source"
fi
