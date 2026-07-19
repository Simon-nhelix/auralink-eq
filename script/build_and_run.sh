#!/usr/bin/env bash
# Compatibility launcher for the canonical Auralink app bundle workflow.
#
# Keep bundle metadata and signing in scripts/bundle-app.sh. Duplicating that
# logic here previously produced an app without NSMicrophoneUsageDescription,
# causing macOS TCC to terminate live routing with SIGABRT.
set -euo pipefail

MODE="${1:-run}"
APP_NAME="AuralinkApp"
BUNDLE_ID="com.auralink.eq"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/build/Auralink EQ.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

case "$MODE" in
  build|--build|run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [build|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

running_pids() {
  pgrep -x "$APP_NAME" 2>/dev/null || true
}

require_app_stopped() {
  local pids
  pids="$(running_pids)"
  if [[ -n "$pids" ]]; then
    echo "error: Auralink EQ is already running (PID(s): ${pids//$'\n'/, })." >&2
    echo "Refusing to kill live audio implicitly. Stop/restart it deliberately, then rerun this command." >&2
    exit 1
  fi
}

require_build_bundle_not_running() {
  local pid command
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" == "$APP_BINARY"* ]]; then
      echo "error: the build/Auralink EQ.app bundle is currently running (PID $pid)." >&2
      echo "Refusing to replace files belonging to a live audio process." >&2
      exit 1
    fi
  done < <(running_pids)
}

stream_logs() {
  exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
}

stream_telemetry() {
  exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
}

# Attach-only modes must not rebuild or touch any app bundle when a live process
# already exists.
if [[ -n "$(running_pids)" ]]; then
  case "$MODE" in
    --logs|logs)
      stream_logs
      ;;
    --telemetry|telemetry)
      stream_telemetry
      ;;
  esac
fi

# New launch/debug/verification runs require exclusive ownership. A build-only
# run remains safe alongside an installed app, but not alongside this exact
# build bundle being executed.
case "$MODE" in
  run|--debug|debug|--verify|verify)
    require_app_stopped
    ;;
  build|--build)
    require_build_bundle_not_running
    ;;
esac

# The canonical builder owns Info.plist generation, stable development signing,
# resource placement, and macOS 26 SwiftUI runtime mitigations.
"$ROOT_DIR/scripts/bundle-app.sh"

if [[ "$MODE" == "build" || "$MODE" == "--build" ]]; then
  exit 0
fi

open_app() {
  # Recheck after the build to close the process-start race.
  require_app_stopped
  /usr/bin/open "$APP_BUNDLE"
}

wait_for_app() {
  local attempt
  for attempt in {1..50}; do
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "error: Auralink EQ did not launch within 5 seconds." >&2
  return 1
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    require_app_stopped
    # LSEnvironment applies only to LaunchServices launches. Export the same
    # macOS 26 executor-check mitigation for a direct LLDB launch.
    export SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=legacy
    exec lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    wait_for_app
    stream_logs
    ;;
  --telemetry|telemetry)
    open_app
    wait_for_app
    stream_telemetry
    ;;
  --verify|verify)
    open_app
    wait_for_app
    ;;
esac
