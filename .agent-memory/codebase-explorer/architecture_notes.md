---
name: architecture notes
description: Lightweight orientation of major mpv subsystems
type: reference
---

Playback and command orchestration live in player, input, and options. Media processing is divided among audio, video, sub, filters, demux, and stream. Rendering and presentation live under video/out, including Direct3D 11, legacy GPU, and GPU-next paths; public embedding interfaces live under include/mpv and player/client.c.
