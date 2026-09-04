#!/bin/bash
#
# Verification for ChordAdmin without Xcode.
#
# The project needs Xcode to build and run for real, but a machine with only the
# Command Line Tools can still typecheck the whole app, exercise the pipeline
# logic, and render the SwiftUI views to PNG. That is enough to catch the large
# majority of mistakes before opening Xcode.
#
#   ./Tools/verify.sh check     typecheck every app source file
#   ./Tools/verify.sh test      build and run the pipeline tests
#   ./Tools/verify.sh render    render the views to Tools/.render-output/*.png
#   ./Tools/verify.sh stress    render every view at the smallest and largest
#                               text sizes, to catch clipping and mid-word breaks
#   ./Tools/verify.sh real      drive the real pipeline against the real backend:
#                                 ./Tools/verify.sh real <youtube-url>
#                                 ./Tools/verify.sh real --audio <file.wav>
#   ./Tools/verify.sh app       build a runnable .app bundle (Firebase stubbed)
#   ./Tools/verify.sh run       build it and launch it
#   ./Tools/verify.sh all       check, test and render (default)
#
set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$TOOLS_DIR")"
APP="$ROOT/ChordAdmin"
BUILD="$TOOLS_DIR/.build"
RENDER_OUT="$TOOLS_DIR/.render-output"

# The 27.0 SDK resolves SwiftUI's @State through a macro plugin that ships with
# Xcode, not the Command Line Tools, so typechecking there fails on every view.
# 26.5 matches the deployment target and needs no plugin.
SDK="${CHORDADMIN_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
TARGET="arm64-apple-macos26.4"

# Mirrors the Xcode target's Swift settings.
SWIFT_FLAGS=(
  -sdk "$SDK"
  -target "$TARGET"
  -swift-version 5
  -default-isolation MainActor
  -enable-upcoming-feature MemberImportVisibility
  -enable-upcoming-feature NonisolatedNonsendingByDefault
  -enable-upcoming-feature InferIsolatedConformances
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability
)

if [ ! -d "$SDK" ]; then
  echo "error: SDK not found at $SDK"
  echo "       set CHORDADMIN_SDK to a macOS SDK that matches the deployment target."
  exit 1
fi

mkdir -p "$BUILD"

# App sources, minus the @main entry point (the harnesses provide their own).
app_sources() {
  find "$APP" -name '*.swift' ! -name 'ChordAdminApp.swift' | sort
}

# Stub Firebase modules, so the real SDK is not needed to compile or link.
build_stubs() {
  for module in FirebaseCore FirebaseAuth FirebaseFirestore; do
    local dylib="$BUILD/lib$module.dylib"
    if [ "$dylib" -nt "$TOOLS_DIR/Stubs/$module.swift" ] 2>/dev/null; then continue; fi
    swiftc -emit-library -emit-module -module-name "$module" \
      -sdk "$SDK" -target "$TARGET" -swift-version 5 \
      -o "$dylib" -emit-module-path "$BUILD/$module.swiftmodule" \
      -Xlinker -install_name -Xlinker "@rpath/lib$module.dylib" \
      "$TOOLS_DIR/Stubs/$module.swift" || return 1
  done
}

link_flags() {
  echo -I "$BUILD" -L "$BUILD" -lFirebaseCore -lFirebaseAuth -lFirebaseFirestore \
       -Xlinker -rpath -Xlinker "$BUILD"
}

run_check() {
  echo "▸ Typechecking $(app_sources | wc -l | tr -d ' ') source files…"
  build_stubs || return 1
  local output
  output=$(swiftc -typecheck "${SWIFT_FLAGS[@]}" -I "$BUILD" $(app_sources) \
           "$APP/ChordAdminApp.swift" 2>&1)
  local errors
  errors=$(grep -c "error:" <<<"$output")
  grep -E "(error|warning):" <<<"$output" | sed "s|$ROOT/||" | sort -u
  if [ "$errors" -gt 0 ]; then
    echo "✗ $errors error(s)"
    return 1
  fi
  echo "✓ typecheck clean"
}

run_test() {
  echo "▸ Building pipeline tests…"
  build_stubs || return 1
  # shellcheck disable=SC2046
  swiftc -o "$BUILD/pipeline-tests" "${SWIFT_FLAGS[@]}" \
    "$APP/AnalysisJob.swift" "$APP/PipelineStage.swift" "$APP/ToolChecker.swift" \
    "$APP/ProcessRunner.swift" "$APP/LocalFileStore.swift" "$APP/JobManager.swift" \
    "$APP/ChartGeneration.swift" "$APP/ChartNavigation.swift" "$APP/SectionStore.swift" \
    "$APP/FirebaseSong.swift" "$APP/StageBeeExportService.swift" \
    "$APP/WorkspaceState.swift" "$APP/Library.swift" "$APP/AppCommands.swift" "$APP/DesignKit.swift" \
    $(link_flags) \
    "$TOOLS_DIR/PipelineTests/FakeBackend.swift" \
    "$TOOLS_DIR/PipelineTests/main.swift" || return 1
  # Never point the file store at the real Application Support data, and never
  # at the real backend — the tests drive a stub on a free port instead.
  local jobs_dir stub_port
  jobs_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordadmin-tests-XXXXXX")
  stub_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  CHORDADMIN_JOBS_DIR="$jobs_dir" \
  CHORDADMIN_BACKEND_URL="http://127.0.0.1:$stub_port" \
    "$BUILD/pipeline-tests"
  local status=$?
  rm -rf "$jobs_dir"
  return $status
}

run_render() {
  echo "▸ Rendering views…"
  build_stubs || return 1
  # shellcheck disable=SC2046
  swiftc -o "$BUILD/render-views" "${SWIFT_FLAGS[@]}" $(link_flags) \
    $(app_sources) "$TOOLS_DIR/RenderViews/main.swift" || return 1

  # Never point the app's file store at the real Application Support data.
  local jobs_dir
  jobs_dir=$(mktemp -d "${TMPDIR:-/tmp}/chordadmin-render-XXXXXX")
  # A scaled sweep writes beside the normal output rather than over it. Local,
  # so a second sweep in the same shell does not stack another suffix on the
  # first one's directory name.
  local out="$RENDER_OUT"
  if [ "${CHORDADMIN_RENDER_SCALE:-1}" != "1" ]; then
    out="$RENDER_OUT-scale${CHORDADMIN_RENDER_SCALE}"
  fi
  rm -rf "$out"
  mkdir -p "$out"
  CHORDADMIN_JOBS_DIR="$jobs_dir" \
  CHORDADMIN_RENDER_SCALE="${CHORDADMIN_RENDER_SCALE:-1}" \
    "$BUILD/render-views" "$out"
  local status=$?
  rm -rf "$jobs_dir"
  echo "  PNGs in $out"
  return $status
}

# A launchable bundle, so the app can actually be run on a machine without
# Xcode. Firebase is the stub, so there is no sign-in and no library — but the
# window, the menus, the front screen and every local interaction are real.
APP_BUNDLE="$BUILD/ChordAdmin.app"

run_app_build() {
  echo "▸ Building ChordAdmin.app…"
  build_stubs || return 1
  local macos="$APP_BUNDLE/Contents/MacOS"
  local frameworks="$APP_BUNDLE/Contents/Frameworks"
  rm -rf "$APP_BUNDLE"
  mkdir -p "$macos" "$frameworks"

  # shellcheck disable=SC2046
  swiftc -o "$macos/ChordAdmin" "${SWIFT_FLAGS[@]}" \
    -I "$BUILD" -L "$BUILD" -lFirebaseCore -lFirebaseAuth -lFirebaseFirestore \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    $(app_sources) "$APP/ChordAdminApp.swift" || return 1

  cp "$BUILD"/libFirebase*.dylib "$frameworks/"

  cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ChordAdmin</string>
  <key>CFBundleExecutable</key><string>ChordAdmin</string>
  <key>CFBundleIdentifier</key><string>local.chordadmin.harness</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0-harness</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

  codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
  echo "✓ $APP_BUNDLE"
}

run_app_launch() {
  run_app_build || return 1
  # Never point a launched app at the real Application Support data.
  local jobs_dir
  jobs_dir="${CHORDADMIN_JOBS_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/chordadmin-run-XXXXXX")}"
  echo "▸ Launching with CHORDADMIN_JOBS_DIR=$jobs_dir"
  CHORDADMIN_JOBS_DIR="$jobs_dir" open -n "$APP_BUNDLE" --args -AppleLanguages "(en)"
}

# Every view at both extremes of the text-size setting. Layout bugs hide at the
# ends of the range, not in the middle: this is what caught the sidebar's
# truncated empty state and "Sections" breaking into "Section" / "s".
run_stress() {
  local failed=0
  for scale in 0.85 1.4; do
    echo "▸ Rendering every view at ${scale}× text…"
    CHORDADMIN_RENDER_SCALE="$scale" run_render | tail -1 || failed=1
  done
  return $failed
}

# The one thing the stub cannot prove: that the app and ChordAdminBackend agree
# in practice. Runs the app's own pipeline code against the real service.
run_real() {
  echo "▸ Building the real-run harness…"
  build_stubs || return 1
  # shellcheck disable=SC2046
  swiftc -o "$BUILD/real-run" "${SWIFT_FLAGS[@]}" \
    "$APP/AnalysisJob.swift" "$APP/PipelineStage.swift" "$APP/ToolChecker.swift" \
    "$APP/ProcessRunner.swift" "$APP/LocalFileStore.swift" "$APP/JobManager.swift" \
    "$APP/ChartGeneration.swift" "$APP/ChartNavigation.swift" "$APP/SectionStore.swift" \
    "$APP/FirebaseSong.swift" "$APP/StageBeeExportService.swift" \
    "$APP/WorkspaceState.swift" "$APP/Library.swift" "$APP/AppCommands.swift" \
    "$APP/DesignKit.swift" \
    $(link_flags) "$TOOLS_DIR/RealRun/main.swift" || return 1

  # Real analysis, but never into the real job store.
  local jobs_dir
  jobs_dir="${CHORDADMIN_JOBS_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/chordadmin-real-XXXXXX")}"
  echo "▸ Job folders: $jobs_dir"
  CHORDADMIN_JOBS_DIR="$jobs_dir" "$BUILD/real-run" "$@"
}

command="${1:-all}"
case "$command" in
  check)  run_check ;;
  stress) run_stress ;;
  real)   shift; run_real "$@" ;;
  app)    run_app_build ;;
  run)    run_app_launch ;;
  test)   run_test ;;
  render) run_render ;;
  all)
    failed=0
    run_check  || failed=1
    echo
    run_test   || failed=1
    echo
    run_render || failed=1
    exit $failed
    ;;
  *)
    echo "usage: $0 [check|test|render|stress|real|app|run|all]"
    exit 2
    ;;
esac
