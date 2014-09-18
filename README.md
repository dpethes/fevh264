fevh264
=======

Baseline h.264 encoder.
Features:
- YUV 4:2:0 colorspace support
- I and P slices
- adaptive I/P slice decision with adjustable max. keyframe interval
- I_4x4, I_16x16, P_L0, P_SKIP macroblock types
- full-pel, half-pel and quarter-pel motion estimation
- unrestricted motion vectors
- multiple reference frames
- in-loop deblocking filter
- fixed QP or 2-pass average bitrate coding mode



Compilation
-----------

Windows and Linux are supported.
Requirements:
- yasm 1.2.0 and later to compile the assembly files
- Lazarus with Freepascal 2.6.x or later

