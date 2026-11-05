#!/bin/sh
# Publie une version : ./release.sh 1.1.0 "Notes de version"
# Exporte le .pck (mise à jour légère), le zip Linux et l'APK, puis crée la release GitHub.
set -e
V="$1"; NOTES="${2:-Version $1}"
[ -n "$V" ] || { echo "usage: $0 <version> [notes]"; exit 1; }
cd "$(dirname "$0")"
REPO=goodview-soft/sound-link
GODOT="flatpak run org.godotengine.Godot"
ENGINE="$($GODOT --version | cut -d. -f1-3)"
OUT=build/release; rm -rf "$OUT"; mkdir -p "$OUT" build/linux

sed -i "s/^const VERSION := .*/const VERSION := \"$V\"/" version.gd
$GODOT --headless --path . --export-pack "Linux" "$OUT/soundlink-$V.pck"
$GODOT --headless --path . --export-release "Linux" build/linux/SoundLink.x86_64
$GODOT --headless --path . --export-debug "Android" "$OUT/SoundLink-$V.apk"
cp install.sh icon.svg LISEZMOI.txt build/linux/
rm -rf build/SoundLink && cp -r build/linux build/SoundLink
(cd build && zip -qr "release/SoundLink-$V-linux.zip" SoundLink) && rm -rf build/SoundLink

# Noms fixes pour les liens « latest » (QR code, install.sh)
cp "$OUT/SoundLink-$V.apk" "$OUT/SoundLink.apk"
cp "$OUT/SoundLink-$V-linux.zip" "$OUT/SoundLink-linux.zip"
cp install.sh "$OUT/install.sh"
rm -f "$OUT"/*.idsig

SHA="$(sha256sum "$OUT/soundlink-$V.pck" | cut -d' ' -f1)"
cat > "$OUT/version.json" <<J
{"version": "$V", "godot": "$ENGINE", "sha256": "$SHA",
 "pck": "https://github.com/$REPO/releases/download/v$V/soundlink-$V.pck"}
J

git add -A && git commit -qm "Version $V" || true
git tag -f "v$V" && git push -q origin HEAD && git push -qf origin "v$V"
gh release create "v$V" --repo "$REPO" --title "Sound Link $V" --notes "$NOTES" "$OUT"/*
echo "Publié : https://github.com/$REPO/releases/tag/v$V"
