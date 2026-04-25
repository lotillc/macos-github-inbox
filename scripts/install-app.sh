#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install-app.sh

Builds the Release app, ad-hoc signs it, and installs it into /Applications.

Environment overrides:
  CONFIGURATION=Release
  DERIVED_DATA_PATH=/path/to/DerivedData
  INSTALL_DIR=/Applications
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PROJECT="GitHubPRInbox.xcodeproj"
SCHEME="GitHubPRInbox"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/build/DerivedData}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP_NAME="GitHubPRInbox.app"

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

install_bundle() {
  if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "error: install directory does not exist: $INSTALL_DIR" >&2
    exit 1
  fi

  if [[ -w "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_PATH"
    ditto "$APP_PATH" "$INSTALL_PATH"
    return
  fi

  require_command sudo
  echo "Installing to $INSTALL_PATH requires administrator privileges."
  sudo rm -rf "$INSTALL_PATH"
  sudo ditto "$APP_PATH" "$INSTALL_PATH"
}

require_command xcodebuild
require_command codesign
require_command ditto

cd "$REPO_ROOT"

echo "Building $SCHEME ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: build did not produce app bundle: $APP_PATH" >&2
  exit 1
fi

echo "Ad-hoc signing $APP_PATH..."
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Installing $APP_NAME to $INSTALL_DIR..."
install_bundle

echo "Installed: $INSTALL_PATH"
