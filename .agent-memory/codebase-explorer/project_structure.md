---
name: project structure
description: Top-level repository structure and directories to skip
type: reference
---

Top-level subsystems include common, options, player, input, filters, video, audio, demux, stream, sub, osdep, ta, include, test, and DOCS. Video output code is under video/out, with d3d11, gpu, gpu_next, hwdec, opengl, placebo, vulkan, win32, and wldmabuf subdirectories. Skip build outputs, .venv, subprojects, and generated/cache directories during source exploration unless dependency internals are specifically relevant.
