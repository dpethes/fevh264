(*******************************************************************************
motion_comp.pas
Copyright (c) 2010-2017 David Pethes

This file is part of Fev.

Fev is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Fev is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Fev.  If not, see <http://www.gnu.org/licenses/>.

*******************************************************************************)

unit motion_comp;
{$mode objfpc}{$H+}

interface

uses
  common, util, frame;

const
  XY_qpel_offset_16x8: array[0..1, 0..1] of byte = ((0, 0), (0, 32));
  MB_pixel_offset_16x8: array[0..1, 0..1] of byte = ((0, 0), (0, 8));

type

  { MotionCompensation }

  MotionCompensation = class
    public
      class procedure Compensate       (const fref: frame_p; const mb: macroblock_t); static;
      class procedure CompensateQPelXY (const fref: frame_p; qx, qy: integer; dst: pbyte); static;
      class procedure CompensateChroma (const fref: frame_p; const mb: macroblock_t); static;
      class procedure CompensateChromaQpelXY(const fref: frame_p; qx, qy: integer; dstU, dstV: pbyte); static;

      class procedure Compensate_16x8       (const fref: frame_p; const mb: macroblock_t; idx: integer); static;
      class procedure CompensateQPelXY_16x8 (const fref: frame_p; qx, qy: integer; dst: pbyte); static;
      class procedure CompensateChroma_8x4  (const fref: frame_p; const mb: macroblock_t; idx: integer); static;
      class procedure CompensateChromaQpelXY_8x4(const fref: frame_p; qx, qy: integer; dstU, dstV: pbyte); static;
  end;


var
  mc_chroma_8x8, mc_chroma_8x4: mc_chroma_func_t;

procedure motion_compensate_init(const flags: TDsp_init_flags);


(*******************************************************************************
*******************************************************************************)
implementation

  {
procedure mv_range_check(const mb: macroblock_t; const fref: frame_p; const fx, fy: integer);
const
  MB_W = 16;
begin
  if (fy >= fref^.ph - MB_W) or (fx >= fref^.pw - MB_W) or (fy < 0) or (fx < 0) then begin
      writeln(stderr, '[motion_compensate_qpel] mv points outside of the frame!');
      //writeln(stderr, 'frame:', h.frame_num);
      writeln(stderr, 'mb type: ', mb.mbtype);
      writeln(stderr, 'mbx/y, mvx/mvy: ', mb.x:3, mb.y:3, mb.mv.x:5, mb.mv.y:5);
      writeln(stderr, 'mvpx/mvpy: ', mb.mvp.x:5, mb.mvp.y:5);
      writeln(stderr, 'mem.pos x/y: ', fx:4, fy:4);
      halt;
  end;
end;
}
(*******************************************************************************
motion_compensate
*)
class procedure MotionCompensation.Compensate(const fref: frame_p; const mb: macroblock_t);
var
  x, y,
  fx, fy: integer;  //fullpel position
  stride: integer;
  j: longword;
begin
  x := mb.x * 64 + mb.mv.x;
  y := mb.y * 64 + mb.mv.y;
  //qpel or hpel / fullpel
  if (x and 1 + y and 1) > 0 then
      CompensateQPelXY(fref, x, y, mb.mcomp)
  else begin
      stride := fref^.stride;
      fx := (x + FRAME_PADDING_W*4) shr 2;
      fy := (y + FRAME_PADDING_W*4) shr 2;
      //mv_range_check(mb, fref, fx, fy);
      j := (y and 2) or (x and 2 shr 1);
      dsp.pixel_loadu_16x16 (mb.mcomp, fref^.luma_mc[j] - fref^.frame_mem_offset + fy * stride + fx, stride);
  end;
end;



class procedure MotionCompensation.CompensateQPelXY(const fref: frame_p; qx, qy: integer; dst: pbyte);
const
{
  plane 1/2 idx
  0..3 - fpelx/y -> fpel/h/v/hv
  4, 5 - fpelx+1/y  fpel/v
  6, 7 - fpelx/y+1  fpel/h
  index: delta y, delta x
}
  qpel_plane_idx: array[0..3, 0..3, 0..1] of byte = (
    ((0,0), (0,1), (1,1), (1,4)),
    ((0,2), (1,2), (1,3), (1,5)),
    ((2,2), (2,3), (3,3), (3,5)),
    ((2,6), (2,7), (3,7), (5,7))
  );
var
  stride: integer;
  fx, fy: integer;   //fullpel
  dx, dy: shortint;  //delta: qpelx/y - fpelx/y * 4
  p1, p2: pbyte;
  plane_idx: pbyte;
  i: integer;

begin
  stride := fref^.stride;
  qx += FRAME_PADDING_W * 4;
  qy += FRAME_PADDING_W * 4;
  fx := qx shr 2;
  fy := qy shr 2;
  dx := qx and 3;
  dy := qy and 3;
  plane_idx := @qpel_plane_idx[dy, dx, 0];
  i := fy * stride + fx - fref^.frame_mem_offset;
  p1 := fref^.luma_mc_qpel[ plane_idx[0] ];
  p2 := fref^.luma_mc_qpel[ plane_idx[1] ];
  if p1 = p2 then
      dsp.pixel_loadu_16x16 (dst, p1 + i, stride)
  else
      dsp.pixel_avg_16x16(p1 + i, p2 + i, dst, stride);
end;



(*******************************************************************************
motion_compensate_chroma

predPartLXC[ xC, yC ] = ( ( 8 – xFracC ) * ( 8 – yFracC ) * A
                          + xFracC * ( 8 – yFracC ) * B
                          + ( 8 – xFracC ) * yFracC * C
                          + xFracC * yFracC * D
                          + 32 ) >> 6
*)
procedure mc_chroma_8x8_pas(src, dst: pbyte; const stride: integer; coef: pbyte); {$ifdef CPUI386} cdecl; {$endif}
var
  i, j: integer;
begin
  for j := 0 to 7 do begin
      for i := 0 to 7 do
          dst[i] := ( coef[0] * src[i]          + coef[1] * src[i + 1]
                    + coef[2] * src[i + stride] + coef[3] * src[i + stride + 1] + 32 ) shr 6;
      dst += 16;
      src += stride;
  end;
end;

procedure mc_chroma_8x4_pas(src, dst: pbyte; const stride: integer; coef: pbyte); {$ifdef CPUI386} cdecl; {$endif}
var
  i, j: integer;
begin
  for j := 0 to 3 do begin
      for i := 0 to 7 do
          dst[i] := ( coef[0] * src[i]          + coef[1] * src[i + 1]
                    + coef[2] * src[i + stride] + coef[3] * src[i + stride + 1] + 32 ) shr 6;
      dst += 16;
      src += stride;
  end;
end;



class procedure MotionCompensation.Compensate_16x8(const fref: frame_p;
  const mb: macroblock_t; idx: integer);
var
  x, y,
  fx, fy: integer;  //fullpel position
  stride: integer;
  j: longword;
  dst: PUInt8;
begin
  if idx = 0 then begin
      x := mb.x * 64 + mb.mv.x + XY_qpel_offset_16x8[idx, 0];
      y := mb.y * 64 + mb.mv.y + XY_qpel_offset_16x8[idx, 1];
  end else
  begin
      x := mb.x * 64 + mb.mv1.x + XY_qpel_offset_16x8[idx, 0];
      y := mb.y * 64 + mb.mv1.y + XY_qpel_offset_16x8[idx, 1];
  end;
  dst := mb.mcomp + MB_pixel_offset_16x8[idx, 0] + MB_pixel_offset_16x8[idx, 1] * 16;  //MB_STRIDE
  //qpel or hpel / fullpel
  if (x and 1 + y and 1) > 0 then
      CompensateQPelXY_16x8(fref, x, y, dst)
  else begin
      stride := fref^.stride;
      fx := (x + FRAME_PADDING_W*4) shr 2;
      fy := (y + FRAME_PADDING_W*4) shr 2;
      //mv_range_check(mb, fref, fx, fy);
      j := (y and 2) or (x and 2 shr 1);
      dsp.pixel_loadu_16x8 (dst, fref^.luma_mc[j] - fref^.frame_mem_offset + fy * stride + fx, stride);
  end;
end;

class procedure MotionCompensation.CompensateQPelXY_16x8(const fref: frame_p; qx,
  qy: integer; dst: pbyte);
const
  qpel_plane_idx: array[0..3, 0..3, 0..1] of byte = (
    ((0,0), (0,1), (1,1), (1,4)),
    ((0,2), (1,2), (1,3), (1,5)),
    ((2,2), (2,3), (3,3), (3,5)),
    ((2,6), (2,7), (3,7), (5,7))
  );
var
  stride: integer;
  fx, fy: integer;   //fullpel
  dx, dy: shortint;  //delta: qpelx/y - fpelx/y * 4
  p1, p2: pbyte;
  plane_idx: pbyte;
  i: integer;

begin
  stride := fref^.stride;
  qx += FRAME_PADDING_W * 4;
  qy += FRAME_PADDING_W * 4;
  fx := qx shr 2;
  fy := qy shr 2;
  dx := qx and 3;
  dy := qy and 3;
  plane_idx := @qpel_plane_idx[dy, dx, 0];
  i := fy * stride + fx - fref^.frame_mem_offset;
  p1 := fref^.luma_mc_qpel[ plane_idx[0] ];
  p2 := fref^.luma_mc_qpel[ plane_idx[1] ];
  if p1 = p2 then
      dsp.pixel_loadu_16x8 (dst, p1 + i, stride)
  else
      dsp.pixel_avg_16x8(p1 + i, p2 + i, dst, stride);
end;


class procedure MotionCompensation.CompensateChroma(const fref: frame_p; const mb: macroblock_t);
var
  x, y: integer;
begin
  x := mb.x * 64 + mb.mv.x;  //qpel position
  y := mb.y * 64 + mb.mv.y;
  CompensateChromaQpelXY(fref, x, y, mb.mcomp_c[0], mb.mcomp_c[1]);
end;

class procedure MotionCompensation.CompensateChromaQpelXY
  (const fref: frame_p; qx, qy: integer; dstU, dstV: pbyte);
var
  fx, fy: integer;  //chroma fullpel
  dx, dy: integer;
  coef: array[0..3] of byte;
  i, stride: integer;
begin
  stride := fref^.stride_c;
  qx += FRAME_PADDING_W * 4;  //qpel position
  qy += FRAME_PADDING_W * 4;
  fx := SarLongint( qx, 3 );
  fy := SarLongint( qy, 3 );
  dx := qx and 7;
  dy := qy and 7;

  coef[0] := (8 - dx) * (8 - dy);
  coef[1] := dx * (8 - dy);
  coef[2] := (8 - dx) * dy;
  coef[3] := dx * dy;
  i := fy * stride + fx - fref^.frame_mem_offset_cr;

  dsp.mc_chroma_8x8(fref^.plane_dec[1] + i, dstU, stride, @coef);
  dsp.mc_chroma_8x8(fref^.plane_dec[2] + i, dstV, stride, @coef);
end;


class procedure MotionCompensation.CompensateChroma_8x4(const fref: frame_p; const mb: macroblock_t; idx: integer);
var
  x, y: integer;
  subpart_offset: integer;
  dstU, dstV: PUInt8;
begin
  if idx = 0 then begin
      x := mb.x * 64 + mb.mv.x + XY_qpel_offset_16x8[idx, 0];
      y := mb.y * 64 + mb.mv.y + XY_qpel_offset_16x8[idx, 1];
  end else
  begin
      x := mb.x * 64 + mb.mv1.x + XY_qpel_offset_16x8[idx, 0];
      y := mb.y * 64 + mb.mv1.y + XY_qpel_offset_16x8[idx, 1];
  end;

  subpart_offset := (MB_pixel_offset_16x8[idx, 0] div 2) + (MB_pixel_offset_16x8[idx, 1] div 2) * 16;  //MB_STRIDE
  dstU := mb.mcomp_c[0] + subpart_offset;
  dstV := mb.mcomp_c[1] + subpart_offset;

  CompensateChromaQpelXY_8x4(fref, x, y, dstU, dstV);
end;

class procedure MotionCompensation.CompensateChromaQpelXY_8x4(const fref: frame_p;
  qx, qy: integer; dstU, dstV: pbyte);
var
  fx, fy: integer;  //chroma fullpel
  dx, dy: integer;
  coef: array[0..3] of byte;
  i, stride: integer;
begin
  stride := fref^.stride_c;
  qx += FRAME_PADDING_W * 4;  //qpel position
  qy += FRAME_PADDING_W * 4;
  fx := SarLongint( qx, 3 );
  fy := SarLongint( qy, 3 );
  dx := qx and 7;
  dy := qy and 7;

  coef[0] := (8 - dx) * (8 - dy);
  coef[1] := dx * (8 - dy);
  coef[2] := (8 - dx) * dy;
  coef[3] := dx * dy;
  i := fy * stride + fx - fref^.frame_mem_offset_cr;

  dsp.mc_chroma_8x4(fref^.plane_dec[1] + i, dstU, stride, @coef);
  dsp.mc_chroma_8x4(fref^.plane_dec[2] + i, dstV, stride, @coef);
end;




(*******************************************************************************
motion_compensate_init
*)
{$ifdef CPUI386}
procedure mc_chroma_8x8_sse2(src, dst: pbyte; const stride: integer; coef: pbyte); cdecl; external;
{$endif}
{$ifdef CPUX86_64}
procedure mc_chroma_8x8_sse2(src, dst: pbyte; const stride: integer; coef: pbyte); external name 'mc_chroma_8x8_sse2';
procedure mc_chroma_8x4_sse2(src, dst: pbyte; const stride: integer; coef: pbyte); external name 'mc_chroma_8x4_sse2';
{$endif}

procedure motion_compensate_init(const flags: TDsp_init_flags);
begin
  mc_chroma_8x8 := @mc_chroma_8x8_pas;
  mc_chroma_8x4 := @mc_chroma_8x4_pas;

  {$ifdef CPUI386}
  if flags.sse2 then begin
      mc_chroma_8x8 := @mc_chroma_8x8_sse2;
  end;
  {$endif}
  {$ifdef CPUX86_64}
  if flags.sse2 then begin
      mc_chroma_8x8 := @mc_chroma_8x8_sse2;
      mc_chroma_8x4 := @mc_chroma_8x4_sse2;
  end;
  {$endif}
end;

end.

