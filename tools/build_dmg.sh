#!/bin/bash
#
# build_dmg.sh — stage and build the operator-facing macOS disk image (.dmg).
#
# Copyright (C) 2026 Seth Johnston.  AGPL-3.0 — see LICENSE.txt.
#
# WHY THIS EXISTS
# The download bundle must be dead simple for a non-technical operator: they
# should open the disk image and see ONE obvious thing to double-click — the
# "Load Audio Players" launcher (the ignition key) — and nothing they could
# click by mistake. So the actual loader, load_content.sh, is tucked into a
# HIDDEN ".loader" sub-folder. The launcher looks there (and beside itself), so
# double-click still works; advanced users can open .loader/load_content.sh in
# Terminal for options like the firmware-update flag (see TECHNICAL.html §4A).
#
# Resulting disk-image layout:
#
#   Audio Player Loader/            (the mounted volume)
#   ├── Load Audio Players.applescript   ← the ONLY thing operators click
#   ├── Operator Guide.html              ← offline, picture-by-picture guide
#   └── .loader/                         ← hidden; advanced/loader machinery
#       ├── load_content.sh                (the loader itself)
#       ├── TECHNICAL.html                 (advanced spec, incl. --firmware)
#       └── LICENSE.txt
#
# REQUIREMENTS: macOS (uses hdiutil). No sudo. Run from anywhere:
#   tools/build_dmg.sh              -> dist/audio-player-loader-macOS.dmg
#   tools/build_dmg.sh /tmp/out.dmg -> that path instead
#
set -euo pipefail

# --- Locate the repo root (this script lives in tools/) ------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VOL_NAME="Audio Player Loader"
OUT="${1:-$REPO_ROOT/dist/audio-player-loader-macOS.dmg}"

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "build_dmg.sh needs macOS (hdiutil not found). Build the .dmg on a Mac." >&2
  exit 1
fi

# --- Sanity: the pieces we ship must all be present ----------------------
LAUNCHER="$REPO_ROOT/Load Audio Players.applescript"
LOADER="$REPO_ROOT/load_content.sh"
GUIDE="$REPO_ROOT/README.html"
TECH="$REPO_ROOT/TECHNICAL.html"
LICENSE="$REPO_ROOT/LICENSE.txt"
for f in "$LAUNCHER" "$LOADER" "$GUIDE" "$TECH" "$LICENSE"; do
  [ -f "$f" ] || { echo "Missing required file: $f" >&2; exit 1; }
done

# --- Stage the layout in a scratch directory -----------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Top level: just the launcher and the friendly offline guide.
cp "$LAUNCHER" "$STAGE/Load Audio Players.applescript"
cp "$GUIDE"    "$STAGE/Operator Guide.html"

# Hidden .loader/: the loader itself plus advanced/reference material. A leading
# dot keeps the whole folder out of the operator's Finder view by default.
mkdir "$STAGE/.loader"
cp "$LOADER"  "$STAGE/.loader/load_content.sh"
cp "$TECH"    "$STAGE/.loader/TECHNICAL.html"
cp "$LICENSE" "$STAGE/.loader/LICENSE.txt"
chmod +x "$STAGE/.loader/load_content.sh"

# --- Build the disk image -------------------------------------------------
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$OUT"

echo
echo "Built: $OUT"
echo "Layout: launcher + Operator Guide.html at top level; load_content.sh in hidden .loader/"
