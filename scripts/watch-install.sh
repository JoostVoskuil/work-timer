#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT/Extensions"
PROJECT="$PROJECT_DIR/WorkTimer.xcodeproj"
DERIVED_DATA="$ROOT/build/XcodeDerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/WorkTimer.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALL_APP="$INSTALL_DIR/WorkTimer.app"
TEAM_ID="${TEAM_ID:-}"
POLL_SECONDS="${POLL_SECONDS:-1}"
ONCE=0

if [[ "${1:-}" == "--once" ]]; then
  ONCE=1
elif [[ $# -ne 0 ]]; then
  echo "Usage: TEAM_ID=YOUR_TEAM_ID $0 [--once]" >&2
  exit 2
fi

if [[ -z "$TEAM_ID" ]]; then
  echo "Set TEAM_ID to your Apple Developer Team ID to sign and install the app extensions." >&2
  echo "Example: TEAM_ID=ABCDE12345 $0" >&2
  exit 2
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install it with: brew install xcodegen" >&2
  exit 2
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required. Install Xcode and select it with xcode-select." >&2
  exit 2
fi

WATCH_PATHS=(
  "$ROOT/Sources"
  "$ROOT/Tests"
  "$PROJECT_DIR/SafariExtension"
  "$PROJECT_DIR/Widgets"
  "$ROOT/scripts"
)
WATCH_FILES=(
  "$ROOT/Package.swift"
  "$PROJECT_DIR/project.yml"
  "$PROJECT_DIR/App.entitlements"
  "$PROJECT_DIR/Safari.entitlements"
  "$PROJECT_DIR/Widgets.entitlements"
)

snapshot() {
  {
    find "${WATCH_PATHS[@]}" -type f -exec stat -f '%m %z %N' {} +
    stat -f '%m %z %N' "${WATCH_FILES[@]}"
  } 2>/dev/null | sort
}

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

stop_app() {
  local pids
  pids="$(/usr/bin/pgrep -x WorkTimer || true)"
  if [[ -n "$pids" ]]; then
    while IFS= read -r pid; do
      kill "$pid"
    done <<< "$pids"
    for _ in {1..50}; do
      /usr/bin/pgrep -x WorkTimer >/dev/null 2>&1 || return 0
      sleep 0.1
    done
    echo "WorkTimer did not quit; refusing to replace the running app." >&2
    return 1
  fi
}

build_install_launch() {
  log "Generating the Xcode project"
  (cd "$PROJECT_DIR" && xcodegen generate) || return $?

  log "Building WorkTimer, Safari extension and widgets"
  xcodebuild \
    -project "$PROJECT" \
    -scheme WorkTimer \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGNING_ALLOWED=YES \
    build || return $?

  if [[ ! -d "$BUILT_APP/Contents/PlugIns/Widgets.appex" || ! -d "$BUILT_APP/Contents/PlugIns/SafariExtension.appex" ]]; then
    echo "The build succeeded but did not embed both app extensions in WorkTimer.app." >&2
    return 1
  fi

  stop_app
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_APP"
  ditto "$BUILT_APP" "$INSTALL_APP" || return $?
  log "Installed $INSTALL_APP"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALL_APP" || return $?
  /usr/bin/pluginkit -a "$INSTALL_APP/Contents/PlugIns/Widgets.appex" || return $?
  log "Refreshed Launch Services and registered the widget extension"
  open -n "$INSTALL_APP" || return $?
  log "Started WorkTimer. Add its widget from Notification Center's Edit Widgets screen."
}

run_build() {
  if build_install_launch; then
    return 0
  fi
  log "Build/install failed; the watcher will retry after the next source change."
  return 1
}

if (( ONCE )); then
  run_build
  exit $?
fi

trap 'log "Stopping watcher"; exit 0' INT TERM
previous="$(snapshot)"
run_build || true
log "Watching app and extension sources for changes"

while true; do
  sleep "$POLL_SECONDS"
  current="$(snapshot)"
  if [[ "$current" != "$previous" ]]; then
    sleep 1
    current="$(snapshot)"
    previous="$current"
    run_build || true
  fi
done
