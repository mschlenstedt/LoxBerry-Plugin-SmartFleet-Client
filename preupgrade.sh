#!/usr/bin/env bash
# SmartFleet Client
# Copyright (c) 2026 Michael Schlenstedt. Alle Rechte vorbehalten.
# Nutzung, Weitergabe und Veraenderung nur nach den Lizenzbedingungen,
# die diesem Programm beiliegen (LICENSE).

pfolder="$3"
lbhomedir="$5"
tempfolder="$6"

quelle="$lbhomedir/config/plugins/$pfolder"

cp -p "$quelle/site.key"   "$tempfolder/" 2>/dev/null
cp -p "$quelle/tunnel.key" "$tempfolder/" 2>/dev/null
cp -p "$quelle/agent.json" "$tempfolder/" 2>/dev/null

exit 0

