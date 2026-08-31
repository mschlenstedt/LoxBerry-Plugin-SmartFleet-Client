#!/usr/bin/env bash
# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

pfolder="$3"
lbhomedir="$5"
tempfolder="$6"

ziel="$lbhomedir/config/plugins/$pfolder"

mkdir -p "$ziel" 2>/dev/null
chmod 0775 "$ziel" 2>/dev/null

cp -p "$tempfolder/site.key"   "$ziel/" 2>/dev/null
cp -p "$tempfolder/tunnel.key" "$ziel/" 2>/dev/null
cp -p "$tempfolder/agent.json" "$ziel/" 2>/dev/null

exit 0

