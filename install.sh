#!/bin/sh
# Installe Sound Link pour l'utilisateur courant (sans mot de passe) :
#   curl -fsSL https://github.com/goodview-soft/sound-link/releases/latest/download/install.sh | sh
# Désinstaller : sh install.sh --uninstall
set -e
APP="$HOME/.local/share/soundlink"
BIN="$HOME/.local/bin/soundlink"
DESK="$HOME/.local/share/applications/soundlink.desktop"
URL="https://github.com/goodview-soft/sound-link/releases/latest/download/SoundLink-linux.zip"

if [ "$1" = "--uninstall" ]; then
	rm -rf "$APP" "$BIN" "$DESK"
	echo "Sound Link désinstallé."
	exit 0
fi

mkdir -p "$APP" "$(dirname "$BIN")" "$(dirname "$DESK")"
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -f "$HERE/SoundLink.x86_64" ]; then
	SRC="$HERE"                        # lancé depuis le zip décompressé
else
	command -v unzip >/dev/null || { echo "Installer d'abord unzip (sudo apt install unzip)."; exit 1; }
	TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
	echo "Téléchargement…"
	curl -fsSL -o "$TMP/sl.zip" "$URL"
	unzip -q "$TMP/sl.zip" -d "$TMP"
	SRC="$TMP/SoundLink"
fi
cp -f "$SRC"/SoundLink.x86_64 "$SRC"/sound-link.sh "$SRC"/icon.svg "$SRC"/install.sh "$APP"/
chmod +x "$APP/SoundLink.x86_64" "$APP/sound-link.sh"
ln -sf "$APP/sound-link.sh" "$BIN"
cat > "$DESK" <<D
[Desktop Entry]
Type=Application
Name=Sound Link
Comment=Partage audio en réseau local
Exec=$APP/sound-link.sh
Icon=$APP/icon.svg
Terminal=false
Categories=AudioVideo;Audio;Network;
D
command -v update-desktop-database >/dev/null && update-desktop-database "$(dirname "$DESK")" 2>/dev/null || true
echo "Sound Link installé : menu des applications, ou commande « soundlink »."
