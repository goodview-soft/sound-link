#!/bin/sh
# Lance Sound Link. Le moteur de capture (share.py) tourne hors du bac à sable flatpak.
DIR="$(cd "$(dirname "$0")" && pwd)"
# libère le port si un ancien moteur l'occupe encore
OLD="$(ss -ltnp 2>/dev/null | sed -n 's/.*127.0.0.1:4245 .*pid=\([0-9]*\).*/\1/p')"
[ -n "$OLD" ] && kill $OLD 2>/dev/null && sleep 1
python3 "$DIR/share.py" 4245 >/dev/null 2>&1 &
ENGINE=$!
trap 'kill $ENGINE 2>/dev/null' EXIT INT TERM
flatpak run org.godotengine.Godot --path "$DIR" "$@"
