#!/bin/sh
# Lance Sound Link. Le moteur de capture (share.py) tourne hors du bac à sable flatpak.
DIR="$(cd "$(dirname "$0")" && pwd)"
# Micro virtuel « Sound-Link-Micro » : l'assistant y parle, le jeu l'utilise comme micro
SINK="$(pactl get-default-sink 2>/dev/null)"; SRC="$(pactl get-default-source 2>/dev/null)"
if ! pactl list short sinks 2>/dev/null | grep -q soundlink_sink; then
	pactl load-module module-null-sink sink_name=soundlink_sink sink_properties=device.description=Sound-Link-Sortie >/dev/null
	pactl load-module module-remap-source master=soundlink_sink.monitor source_name=soundlink_mic source_properties=device.description=Sound-Link-Micro >/dev/null
	[ -n "$SINK" ] && pactl set-default-sink "$SINK"
	[ -n "$SRC" ] && pactl set-default-source "$SRC"
fi
# libère le port si un ancien moteur l'occupe encore
OLD="$(ss -ltnp 2>/dev/null | sed -n 's/.*127.0.0.1:4245 .*pid=\([0-9]*\).*/\1/p')"
[ -n "$OLD" ] && kill $OLD 2>/dev/null && sleep 1
python3 "$DIR/share.py" 4245 >/dev/null 2>&1 &
ENGINE=$!
trap 'kill $ENGINE 2>/dev/null' EXIT INT TERM
flatpak run org.godotengine.Godot --path "$DIR" "$@"
