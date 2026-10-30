#!/bin/bash
# Build-time packaging only. End users open ChordAdmin; no setup happens at launch.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
backend_source="${CHORDADMIN_BACKEND_SOURCE:-/Volumes/ChordAdminBackendArchive/ChordAdminBackend}"
if [[ ! -d "$backend_source" ]]; then
  echo "Backend source unavailable. Mount /Volumes/T7/Backups/Retired Projects/ChordAdminBackend.sparseimage or set CHORDADMIN_BACKEND_SOURCE." >&2
  exit 1
fi
packaging_python="${CHORDADMIN_PACKAGING_PYTHON:-$backend_source/.venv/bin/python}"
signing_identity="${CHORDADMIN_SIGNING_IDENTITY:?Set CHORDADMIN_SIGNING_IDENTITY to your signing certificate hash}"
derived_path="${CHORDADMIN_DERIVED_DATA:-/tmp/chordadmin-packaged-derived}"
cd "$repo_root"
mkdir -p Tools/.runtime-build
packager_dir=$(mktemp -d "$repo_root/Tools/.runtime-build/packager.XXXXXX")
trap 'rm -rf "$packager_dir"' EXIT
"$packaging_python" -m pip install --target "$packager_dir" -r Tools/Backend/packaging-requirements.txt
PYTHONPATH="$packager_dir" "$packaging_python" Tools/Backend/build_runtime.py --source "$backend_source"
python3 Tools/Backend/sign_runtime.py Tools/.runtime-dist/ChordAdminAnalysis.app --identity "$signing_identity"
xcodebuild -project ChordAdmin.xcodeproj -scheme ChordAdmin -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$derived_path" build
codesign --verify --deep --strict "$derived_path/Build/Products/Debug/ChordAdmin.app"
echo "$derived_path/Build/Products/Debug/ChordAdmin.app"
