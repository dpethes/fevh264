fevh264
=======

Baseline h.264 encoder.
Supported standard features:
- YUV 4:2:0 colorspace support
- I and P slices
- I_4x4, I_16x16, P_L0, P_SKIP macroblock types
- full-pel, half-pel and quarter-pel motion estimation
- unrestricted motion vectors
- multiple reference frames
- in-loop deblocking filter

Encoder features:
- adaptive I/P slice decision with adjustable max. keyframe interval
- fixed QP or 2-pass average bitrate coding mode
- tunable motion estimation quality (subpixel ME refinement, reference frame count)
- tunable macroblock type decision quality
- assembly optimizations (x86/x64 MMX/SSE2)
- multithreaded deblocking

Accepted input file types:
- raw YUV 4:2:0 (width and height requied)
- YUV4MPEG 4:2:0 (*.y4m)
- Avisynth script (*.avs, Windows only)

Compilation
-----------

Windows and Linux are supported.
Requirements:
- yasm 1.2.0 and later to compile the assembly files
- Lazarus with Freepascal 3.0.x or later

