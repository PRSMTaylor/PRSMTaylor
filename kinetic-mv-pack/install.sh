#!/usr/bin/env bash
# Installs (or removes with --uninstall) the KMV effects pack for DaVinci Resolve on macOS.
# Use --all-users to install to /Library instead of the current user's Library.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
rel="Blackmagic Design/DaVinci Resolve/Fusion/Templates/Edit/Effects"
base="$HOME/Library/Application Support"
mode=install
for a in "$@"; do
  case "$a" in
    --uninstall) mode=uninstall ;;
    --all-users) base="/Library/Application Support" ;;
    *) echo "Unknown option: $a" >&2; exit 1 ;;
  esac
done
dest="$base/$rel"
sdest="$base/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit"
if [ "$mode" = uninstall ]; then
  rm -f "$dest"/KMV\ *.setting "$sdest"/KMV\ *.lua
  echo "Removed KMV presets from $dest and scripts from $sdest"
  exit 0
fi
mkdir -p "$dest" "$sdest"
cp "$here"/Effects/KMV\ *.setting "$dest"/
cp "$here"/Scripts/KMV\ *.lua "$sdest"/
echo "Installed presets to $dest"
echo "Installed launcher script to $sdest (Workspace > Scripts > Edit)"
echo 'Restart DaVinci Resolve, then search "KMV" in Effects > Edit Effects.'
