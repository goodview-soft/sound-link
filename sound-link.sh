#!/bin/sh
# Lance Sound Link en faisant de la sortie son du PC (monitor) la source "Default" de Godot.
# Crée aussi un micro virtuel « Sound-Link-Micro » où le host joue les micros des clients.
DIR="$(cd "$(dirname "$0")" && pwd)"
SINK="$(pactl get-default-sink 2>/dev/null)"
SRC="$(pactl get-default-source 2>/dev/null)"
if ! pactl list short sinks 2>/dev/null | grep -q soundlink_sink; then
	pactl load-module module-null-sink sink_name=soundlink_sink sink_properties=device.description=Sound-Link-Sortie >/dev/null
	pactl load-module module-remap-source master=soundlink_sink.monitor source_name=soundlink_mic source_properties=device.description=Sound-Link-Micro >/dev/null
	# Ne pas laisser le système basculer ses périphériques par défaut sur les virtuels
	[ -n "$SINK" ] && pactl set-default-sink "$SINK"
	[ -n "$SRC" ] && pactl set-default-source "$SRC"
fi
exec flatpak run --env=PULSE_SOURCE="${SINK}.monitor" org.godotengine.Godot --audio-driver PulseAudio --path "$DIR" "$@"
