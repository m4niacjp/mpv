---
name: architecture notes
description: Where visual quality and user detail modes live
type: project
---

Upstream quality presets: `etc/builtin.conf` (`high-quality`, `fast`). Option docs: `DOCS/man/options.rst`. User High/Low Detail: Roaming `[detail-high]`/`[detail-low]` + `quick-menu.lua` + `remember-rtx.lua`. RTX AI upscale: Roaming `rtx-video-auto.lua` via `d3d11vpp`, orthogonal to detail profiles.
