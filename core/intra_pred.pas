(*******************************************************************************
intra_pred.pas
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

unit intra_pred;
{$mode objfpc}{$H+}

interface

uses
  common, util, pixel, h264stream;

type
  TPredict4x4Func = procedure (src, dst: PUint8; stride: integer);
  TPredict16x16Func = procedure (src, dst: PUint8); {$ifdef CPUI386} cdecl; {$endif}
  TPredict16x16DcFunc = procedure (src, dst: PUint8; mbx, mby: longword);

  { TIntraPredictor }

  TIntraPredictor = class
    private
      mbcmp_16x16,
      mbcmp_8x8,
      mbcmp_4x4: mbcmp_func_t;
      pred4_cache: array[0..8] of pbyte;  //cache for 4x4 predicted pixels
      //luma
      pixels,
      prediction: pbyte;
      frame_stride: integer;
      //chroma
      pixels_c,
      prediction_c: array[0..1] of pbyte;
      stride_c: integer;
      pixel_cache: pbyte;
      mb_width: integer;
      mb: macroblock_p;

    public
      LastScore: integer;

      constructor Create;
      destructor Free;
      procedure UseSATDCompare;
      procedure SetMB(const mb_: macroblock_p);
      procedure SetFrame(const frame: frame_p);
      procedure Predict_4x4   (mode: integer; ref: pbyte; mbx, mby, n: integer);
      procedure Predict_8x8_chroma(mode: integer; refU, refV: pbyte; mbx, mby: integer);
      procedure Predict_16x16 (mode: integer; mbx, mby: integer);

      //Get best mode for i4x4 prediction. Also stores the predicted pixels
      function  Analyse_4x4(const ref: pbyte; const n: integer): integer;
      function  Analyse_8x8_chroma(refU, refV: pbyte): integer;
      function  Analyse_16x16(): integer;
  end;

var
  predict_top16,
  predict_left16,
  predict_plane16: TPredict16x16Func;
  predict_dc16: TPredict16x16DcFunc;

procedure intra_pred_init(const flags: TDsp_init_flags);


(*******************************************************************************
*)
implementation

const
  I4x4CACHE_STRIDE = 16;

(* top *)
procedure predict_top4( src, dst: PUint8; sstride: integer );
var
  p: int32;
  i: integer;
begin
  src -= sstride;
  p := Pint32(src)^;
  for i := 0 to 3 do begin
      Pint32(dst)^ := p;
      dst += I4x4CACHE_STRIDE;
  end;
end;


(* left *)
procedure predict_left4( src, dst: PUint8; sstride: integer );
var
  i: integer;
begin
  src -= 1;
  for i := 0 to 3 do begin
      PUInt32(dst)^ := src^ * uint32($01010101);
      src += sstride;
      dst += I4x4CACHE_STRIDE;
  end;
end;


(* dc *)
procedure predict_dc4( src, dst: PUint8; sstride: integer; mbx, mby, n: word);
var
  has_top, has_left: boolean;
  i, shift: integer;
  dc: uint32;
begin
  has_top  := (mby > 0) or not(n in [0,1,4,5]);
  has_left := (mbx > 0) or not(n in [0,2,8,10]);
  dc := 0;
  shift := 0;
  if has_top then begin
      for i := 0 to 3 do
          dc += src[i - sstride];
      shift := 2;
  end;
  if has_left then begin
      for i := 0 to 3 do
          dc += src[-1 + i * sstride];
      shift += 2;
  end;

  if shift = 4 then
      dc := (dc + 4) shr 3
  else if shift = 2 then
      dc := (dc + 2) shr 2
  else
      dc := 128;

  dc *= uint32($01010101);
  for i := 0 to 3 do begin
      PUInt32(dst)^ := dc;
      dst += I4x4CACHE_STRIDE;
  end;
end;


{ 8.3.1.2.4  Specification of Intra_4x4_Diagonal_Down_Left prediction mode
If x is equal to 3 and y is equal to 3,
  pred4x4L[x, y] = ( p[6, -1] + 3 * p[7, -1] + 2 ) >> 2
Otherwise (x is not equal to 3 or y is not equal to 3),
  pred4x4L[x, y] = ( p[x + y, -1] + 2 * p[x + y + 1, -1] + p[x + y + 2, -1] + 2 ) >> 2
}
procedure predict_ddl4( src, dst: PUint8; sstride: integer );
var
  x, y: integer;
begin
  src := src - sstride;
  for y := 0 to 3 do
      for x := 0 to 3 do
          dst[y * I4x4CACHE_STRIDE + x] := ( src[x + y]
                             + src[x + y + 1] * 2
                             + src[x + y + 2] + 2) shr 2;
  dst[3 * I4x4CACHE_STRIDE + 3] := (src[6] + 3 * src[7] + 2) shr 2
end;


{ 8.3.1.2.5  Specification of Intra_4x4_Diagonal_Down_Right prediction mode
If x is greater than y,
  pred4x4L[x, y] = ( p[x - y - 2, -1]   + 2 * p[x - y - 1, -1]  + p[x - y, -1] + 2 ) >> 2
Otherwise if x is less than y,
  pred4x4L[x, y] = ( p[-1, y - x - 2]   + 2 * p[-1, y - x - 1]  + p[-1, y - x] + 2 ) >> 2
Otherwise (x is equal to y),
  pred4x4L[x, y] = ( p[0, -1] + 2 * p[-1, -1] + p[-1, 0] + 2 ) >> 2
}
procedure predict_ddr4( src, dst: PUint8; sstride: integer );
var
  x, y: integer;
begin
  for y := 0 to 3 do
      for x := 0 to 3 do
          if x > y then
              dst[y * I4x4CACHE_STRIDE + x] := ( src[x - y - 2 - sstride]
                                 + src[x - y - 1 - sstride] * 2
                                 + src[x - y     - sstride] + 2) shr 2
          else if x < y then
              dst[y * I4x4CACHE_STRIDE + x] := ( src[-1 + (y - x - 2) * sstride]
                                 + src[-1 + (y - x - 1) * sstride] * 2
                                 + src[-1 + (y - x    ) * sstride] + 2) shr 2
          else {x = y}
              dst[y * I4x4CACHE_STRIDE + x] := ( src[-sstride    ]
                                 + src[-1 - sstride] * 2
                                 + src[-1          ] + 2) shr 2
end;


(* vertical right *)
procedure predict_vr4( src, dst: PUint8; stride: integer );
var
  z, x, y, i: integer;
begin
  for x := 0 to 3 do
      for y := 0 to 3 do begin
          z := 2 * x - y;
          if z >= 0 then begin
              i := x - (y shr 1) - stride;
              if (z and 1) = 0 then
                  dst[x+y*I4x4CACHE_STRIDE] := (src[i - 1]
                                + src[i] + 1) div 2
              else
                  dst[x+y*I4x4CACHE_STRIDE] := (src[i - 2]
                                + src[i - 1] * 2
                                + src[i] + 2) div 4
          end  else if z = -1 then
                  dst[x+y*I4x4CACHE_STRIDE] := (src[-1] + src[-1 - stride] * 2 + src[-stride] + 2) div 4
          else
                  dst[x+y*I4x4CACHE_STRIDE] := (src[-1 + (y - x - 1) * stride]
                                + src[-1 + (y - x - 2) * stride] * 2
                                + src[-1 + (y - x - 3) * stride] + 2) div 4;
      end;
end;


(* vertical left *)
procedure predict_vl4( src, dst: PUint8; stride: integer );
var
  x, y: integer;
begin
  for x := 0 to 3 do
      for y := 0 to 3 do
          if (y and 1) = 1 then
              dst[x+y*I4x4CACHE_STRIDE] := (src[x + (y shr 1)     - stride]
                            + src[x + (y shr 1) + 1 - stride] * 2
                            + src[x + (y shr 1) + 2 - stride] + 2) div 4
              //P[x,y] = (S[x+(y/2),-1] + 2 * S[x+(y/2)+1,-1] + S[x+(y/2)+2,-1] + 2) / 4
          else
              dst[x+y*I4x4CACHE_STRIDE] := (src[x + (y shr 1)     - stride]
                            + src[x + (y shr 1) + 1 - stride] + 1) div 2;
              //P[x,y] = (S[x+(y/2),-1] + S[x+(y/2)+1,-1] + 1) / 2
end;


(* horiz down *)
procedure predict_hd4( src, dst: PUint8; stride: integer );
var
  z, x, y, i: integer;
begin
  for x := 0 to 3 do
      for y := 0 to 3 do begin
          z := 2 * y - x;
          if z >= 0 then begin
              i := y - (x shr 1);
              if (z and 1) = 0 then
                  dst[x+y*I4x4CACHE_STRIDE] := (src[-1 + (i - 1) * stride]
                                + src[-1 + i       * stride] + 1) div 2
                  //P[x,y] = (S[-1,y-(x/2)-1] + S[-1,y-(x/2)] + 1) / 2
              else
                  dst[x+y*I4x4CACHE_STRIDE] := (src[-1 + (i - 2) * stride]
                                + src[-1 + (i - 1) * stride] * 2
                                + src[-1 + i       * stride] + 2) div 4
                  //P[x,y] = (S[-1,y-(x/2)-2] + 2 * S[-1,y-(x/2)-1] + S[-1,y-(x/2)] + 2) / 4
          end else if z = -1 then
                  dst[x+y*I4x4CACHE_STRIDE] := (src[-1] + src[-1 - stride] * 2 + src[-stride] + 2) div 4
                  //P[x,y] = (S[-1,0] + 2 * S[-1,-1] + S[0,-1] + 2) / 4
          else begin
                  i := x - y - 1 - stride;
                  dst[x+y*I4x4CACHE_STRIDE] := (src[i]
                                + src[i - 1] * 2
                                + src[i - 2] + 2) div 4;
          end;
                  //P[x,y] = (S[x-y-1,-1] + 2 * S[x-y-2,-1] + S[x-y-3,-1] + 2) / 4
      end;
end;


{ 8.3.1.2.9 Specification of Intra_4x4_Horizontal_Up prediction mode
zHU be set equal to x + 2 * y.
- If zHU is equal to 0, 2, or 4
pred4x4L[ x, y ] = ( p[ -1, y + ( x >> 1 ) ] + p[ -1, y + ( x >> 1 ) + 1 ] + 1 ) >> 1
- Otherwise, if zHU is equal to 1 or 3
pred4x4L[ x, y ] = ( p[ -1, y + ( x >> 1 ) ] + 2 * p[ -1, y + ( x >> 1 ) + 1 ] + p[ -1, y + ( x >> 1 ) + 2 ] + 2 ) >> 2
- Otherwise, if zHU is equal to 5,
pred4x4L[ x, y ] = ( p[ -1, 2 ] + 3 * p[ -1, 3 ] + 2 ) >> 2
- Otherwise (zHU is greater than 5),
pred4x4L[ x, y ] = p[ -1, 3 ]
}
procedure predict_hu4( src, dst: PUint8; stride: integer );
var
  z, x, y, i: integer;
begin
  for x := 0 to 3 do
      for y := 0 to 3 do begin
          z := x + 2 * y;
          if (z >= 0) and (z < 5) then begin
              i := y + (x shr 1);
              if (z and 1) = 0 then
                  dst[x+y*I4x4CACHE_STRIDE] := (src[-1 + i * stride]
                                + src[-1 + (i + 1) * stride] + 1) shr 1
              else
                  dst[x+y*I4x4CACHE_STRIDE] := (src[-1 +       i * stride]
                                + src[-1 + (i + 1) * stride] * 2
                                + src[-1 + (i + 2) * stride] + 2) shr 2
          end else if z = 5 then
                  dst[x+y*I4x4CACHE_STRIDE] := (src[-1 + 2 * stride]
                                + src[-1 + 3 * stride] * 3 + 2) shr 2
          else
                  dst[x+y*I4x4CACHE_STRIDE] := src[-1 + 3 * stride];
      end;
end;


(*******************************************************************************
8.3.2 Intra_16x16 prediction process for luma samples
*******************************************************************************)
procedure predict_top16_pas(src, dst: PUint8); {$ifdef CPUI386} cdecl; {$endif}
var
  p1, p2: int64;
  i: integer;
begin
  p1 := PInt64(src+1)^;
  p2 := PInt64(src+9)^;
  for i := 0 to 7 do begin
      PInt64(dst   )^ := p1;
      PInt64(dst+8 )^ := p2;
      PInt64(dst+16)^ := p1;
      PInt64(dst+24)^ := p2;
      dst += 32;
  end;
end;


procedure predict_left16_pas(src, dst: PUint8); {$ifdef CPUI386} cdecl; {$endif}
var
  i: integer;
  v: uint64;
begin
  src += 18;
  for i := 0 to 15 do begin
      v := src^ * uint64($0101010101010101);
      PUInt64(dst  )^ := v;
      PUInt64(dst+8)^ := v;
      src += 1;
      dst += 16;
  end;
end;


procedure predict_dc16_pas(src, dst: PUint8; mbx, mby: longword);
var
  dc, i, avail: integer;
begin
  dc := 0;
  avail := 0;
  if mby > 0 then begin
      for i := 1 to 16 do
          dc += src[i];
      avail += 1;
  end;
  if mbx > 0 then begin
      for i := 18 to 33 do
          dc += src[i];
      avail += 1;
  end;

  if avail = 2 then
      dc := (dc + 16) shr 5
  else if avail = 1 then
      dc := (dc + 8) shr 4
  else
      dc := 128;

  FillByte(dst^, 256, byte(dc));
end;


procedure predict_plane16_pas(src, dst: PUint8); {$ifdef CPUI386} cdecl; {$endif}
var
  x, y: integer;
  a, b, c, d, h, v, i: integer;

begin
  h := 0;
  v := 0;
  src += 1;

  for i := 0 to 7 do begin
      h += (i + 1) * (src[8 + i]      - src[6 - i]);
      v += (i + 1) * (src[17 + 8 + i] - src[17 + 6 - i]);
  end;

  a := 16 * ( src[15 + 17] + src[15] ) + 16;
  b := SarSmallint( 5 * h + 32, 6 );
  c := SarSmallint( 5 * v + 32, 6 );

  for y := 0 to 15 do begin
      d := a + c * (y - 7);
      for x := 0 to 15 do begin
          i := b * (x - 7) + d;
          if i < 0 then
              dst[x] := 0
          else begin
              i := i shr 5;
              if i > 255 then i := 255;
              dst[x] := byte(i);
          end;
      end;
      dst += 16;
  end;
end;


(*******************************************************************************
8.3.3 Intra prediction process for chroma samples
*******************************************************************************)
procedure predict_dc8( src, dst: PUint8; sstride: integer; mbx, mby: word);
var
  has_top, has_left: boolean;
  i: integer;
  dc, shift: integer;
  dcf: array[0..3] of uint32;

begin
  has_top  := mby > 0;
  has_left := mbx > 0;

  //0
  dc := 0;
  shift := 0;
  if has_top then begin
      for i := 0 to 3 do
          dc += src[i - sstride];
      shift := 2;
  end;
  if has_left then begin
      for i := 0 to 3 do
          dc += src[-1 + i * sstride];
      shift += 2;
  end;
  if shift = 4 then
      dc := (dc + 4) shr 3
  else if shift = 2 then
      dc := (dc + 2) shr 2
  else
      dc := 128;
  dcf[0] := dc;

  //1
  dc := 0;
  if has_top then begin
      for i := 0 to 3 do
          dc += src[4 + i - sstride];
      dc := (dc + 2) shr 2;
  end else if has_left then begin
      for i := 0 to 3 do
          dc += src[-1 + i * sstride];
      dc := (dc + 2) shr 2;
  end else
      dc := 128;
  dcf[1] := dc;

  //2
  dc := 0;
  if has_left then begin
      for i := 0 to 3 do
          dc += src[-1 + (i + 4) * sstride];
      dc := (dc + 2) shr 2;
  end else if has_top then begin
      for i := 0 to 3 do
          dc += src[i - sstride];
      dc := (dc + 2) shr 2;
  end else
      dc := 128;
  dcf[2] := dc;

  //3
  dc := 0;
  shift := 0;
  if has_top then begin
      for i := 0 to 3 do
          dc += src[4 + i - sstride];
      shift := 2;
  end;
  if has_left then begin
      for i := 0 to 3 do
          dc += src[-1 + (4 + i) * sstride];
      shift += 2;
  end;
  if shift = 4 then
      dc := (dc + 4) shr 3
  else if shift = 2 then
      dc := (dc + 2) shr 2
  else
      dc := 128;
  dcf[3] := dc;

  //write
  dcf[0] *= $01010101;
  dcf[1] *= $01010101;
  dcf[2] *= $01010101;
  dcf[3] *= $01010101;
  for i := 0 to 3 do begin
      PUInt32(dst  )^ := dcf[0];
      PUInt32(dst+4)^ := dcf[1];
      dst += 16;
  end;
  for i := 0 to 3 do begin
      PUInt32(dst  )^ := dcf[2];
      PUInt32(dst+4)^ := dcf[3];
      dst += 16;
  end;
end;


procedure predict_top8( src, dst: PUint8; sstride: integer );
var
  p: int64;
  i: integer;
begin
  src -= sstride;
  p := PInt64(src)^;
  for i := 0 to 7 do begin
      PInt64(dst)^ := p;
      dst += 16;
  end;
end;


procedure predict_left8( src, dst: PUint8; sstride: integer );
var
  i: integer;
begin
  src -= 1;
  for i := 0 to 7 do begin
      PUInt64(dst)^ := src^ * uint64($0101010101010101);
      src += sstride;
      dst += 16;
  end;
end;


procedure predict_plane8( src, dst: PUint8; stride: integer);
var
  x, y: integer;
  a, b, c, d, h, v, i: integer;

begin
  h := 0;
  v := 0;

  for x := 0 to 3 do
      h += (x + 1) * (src[-stride + 4 + x] - src[-stride + 2 - x]);
  for y := 0 to 3 do
      v += (y + 1) * (src[(4 + y) * stride - 1] - src[(2 - y) * stride - 1]);

  a := 16 * ( src[7 * stride - 1] + src[-stride + 7] ) + 16;
  b := SarSmallint( 17 * h + 16, 5 );
  c := SarSmallint( 17 * v + 16, 5 );

  for y := 0 to 7 do begin
      d := a + c * (y - 3);
      for x := 0 to 7 do begin
          i := b * (x - 3) + d;
          if i < 0 then
              dst[x] := 0
          else begin
              i := i shr 5;
              if i > 255 then i := 255;
              dst[x] := byte(i);
          end;
      end;
      dst += 16;
  end;
end;


const
  Predict4x4Funcs: array[INTRA_PRED_TOP..INTRA_PRED_HU] of TPredict4x4Func = (
      @predict_top4,
      @predict_left4,
      nil, //INTRA_PRED_DC is different
      @predict_ddl4,
      @predict_ddr4,
      @predict_vr4,
      @predict_hd4,
      @predict_vl4,
      @predict_hu4
  );

{ TIntraPredictor }

constructor TIntraPredictor.Create;
var
  i: integer;
begin
  mbcmp_16x16 := dsp.sad_16x16;
  mbcmp_8x8 := dsp.sad_8x8;
  mbcmp_4x4 := dsp.sad_4x4;
  pred4_cache[0] := fev_malloc(9*4*I4x4CACHE_STRIDE);
  for i := 1 to 8 do
      pred4_cache[i] := pred4_cache[i-1] + 4*I4x4CACHE_STRIDE;
end;

destructor TIntraPredictor.Free;
begin
  fev_free(pred4_cache[0]);
end;

procedure TIntraPredictor.UseSATDCompare;
begin
  mbcmp_16x16 := dsp.satd_16x16;
  mbcmp_8x8 := dsp.satd_8x8;
  mbcmp_4x4 := dsp.satd_4x4;
end;

procedure TIntraPredictor.SetMB(const mb_: macroblock_p);
begin
  mb := mb_;
  pixels      := mb^.pixels;
  prediction  := mb^.pred;
  pixels_c[0] := mb^.pixels_c[0];
  pixels_c[1] := mb^.pixels_c[1];
  prediction_c[0] := mb^.pred_c[0];
  prediction_c[1] := mb^.pred_c[1];
  pixel_cache := @(mb^.intra_pixel_cache);
end;

procedure TIntraPredictor.SetFrame(const frame: frame_p);
begin
  frame_stride := frame^.stride;
  stride_c := frame^.stride_c;
  mb_width := frame^.mbw;
end;


procedure TIntraPredictor.Predict_4x4(mode: integer; ref: pbyte; mbx, mby, n: integer);
begin
  Assert(mode <= 8, 'unknown predict mode');
  if mode = INTRA_PRED_DC then
      predict_dc4(ref, prediction + BLOCK_OFFSET_4[n], frame_stride, mbx, mby, n)
  else
      Predict4x4Funcs[mode](ref, prediction + BLOCK_OFFSET_4[n], frame_stride);
end;


procedure TIntraPredictor.Predict_8x8_chroma(mode: integer; refU, refV: pbyte; mbx, mby: integer);
begin
  Assert(mode <= 3, 'unknown chroma predict mode');
  case mode of
      INTRA_PRED_CHROMA_DC: begin
          predict_dc8   (refU, prediction_c[0], stride_c, mbx, mby);
          predict_dc8   (refV, prediction_c[1], stride_c, mbx, mby);
      end;
      INTRA_PRED_CHROMA_TOP: begin
          predict_top8  (refU, prediction_c[0], stride_c);
          predict_top8  (refV, prediction_c[1], stride_c);
      end;
      INTRA_PRED_CHROMA_LEFT: begin
          predict_left8 (refU, prediction_c[0], stride_c);
          predict_left8 (refV, prediction_c[1], stride_c);
      end;
      INTRA_PRED_CHROMA_PLANE: begin
          predict_plane8(refU, prediction_c[0], stride_c);
          predict_plane8(refV, prediction_c[1], stride_c);
      end;
  end;
end;


procedure TIntraPredictor.Predict_16x16(mode: integer; mbx, mby: integer);
begin
  Assert(mode <= 3, 'unknown chroma predict mode');
  case mode of
      INTRA_PRED_DC:
          predict_dc16   (pixel_cache, prediction, mbx, mby);
      INTRA_PRED_TOP:
          predict_top16  (pixel_cache, prediction);
      INTRA_PRED_LEFT:
          predict_left16 (pixel_cache, prediction);
      INTRA_PRED_PLANE:
          predict_plane16(pixel_cache, prediction);
  end;
end;


function TIntraPredictor.Analyse_4x4(const ref: pbyte; const n: integer): integer;
const
  TopMask        = %1111111111001100;  //!(n in [0, 1, 4, 5])
  LeftMask       = %1111101011111010;  //!(n in [0, 2, 8, 10])
  TopLeftMask    = %1111101011001000;  //n in [3, 6, 7, 9, 11, 12, 13, 14, 15]
  InsideTTRMask  = %0101011101000100;  //top/topright, n in [2, 6, 8, 9, 10, 12, 14]
  OutsideTTRMask = %0101011101110111;  //top/topright, !(n in [3, 7, 11, 13, 15])
  MISPREDICTION_COST = 3 * 4; //TODO suitable for qp ~22, needs to be qp modulated
var
  pix: pbyte;
  modes, mode: integer;
  score, min_score: integer;
  mask, mbx, mby: integer;
  has_top, has_left, has_tl, has_inside_ttr, has_outside_ttr: Boolean;
  predicted_mode: Byte;
begin
  pix := pixels + BLOCK_OFFSET_4[n];
  mbx := mb^.x;
  mby := mb^.y;

  predicted_mode := predict_intra_4x4_mode(mb^.i4_pred_mode, n);

  //always run dc
  mode := INTRA_PRED_DC;
  predict_dc4 (ref, pred4_cache[mode], frame_stride, mbx, mby, n);
  min_score := mbcmp_4x4(pix, pred4_cache[mode], I4x4CACHE_STRIDE);
  if predicted_mode <> mode then
      min_score += MISPREDICTION_COST;
  result := mode;
  modes := 0;

  //rules based on the 4x4 block position inside 16x16 macroblock
  mask := 1 << n;
  has_top  := (TopMask     and mask) > 0;
  has_left := (LeftMask    and mask) > 0;
  has_tl   := (TopLeftMask and mask) > 0;
  has_inside_ttr  := (InsideTTRMask  and mask) > 0;
  has_outside_ttr := (OutsideTTRMask and mask) > 0;

  //enable modes that need:
  //top pixels
  if (mby > 0) or has_top then
      modes := modes or (1 << INTRA_PRED_TOP);
  //left pixels
  if (mbx > 0) or has_left then
      modes := modes or (1 << INTRA_PRED_LEFT) or (1 << INTRA_PRED_HU);
  //top & left pixels
  if ((mbx > 0) and (mby > 0)) or has_tl then
      modes := modes or (1 << INTRA_PRED_DDR) or (1 << INTRA_PRED_VR) or (1 << INTRA_PRED_HD);
  //top & top-right pixels (we could use sample substitution instead of last-in-a-row check for top-right pixels)
  if ((mby > 0) and (mbx < mb_width - 1) and has_outside_ttr) or has_inside_ttr then
      modes := modes or (1 << INTRA_PRED_DDL) or (1 << INTRA_PRED_VL);

  //run all enabled modes
  for mode := 0 to 8 do begin
      if ((1 << mode) and modes) > 0 then begin
          Predict4x4Funcs[mode](ref, pred4_cache[mode], frame_stride);
          score := mbcmp_4x4(pix, pred4_cache[mode], I4x4CACHE_STRIDE);
          if predicted_mode <> mode then
              score += MISPREDICTION_COST;
          if score < min_score then begin
              min_score := score;
              result := mode;
          end;
      end;
  end;
  LastScore += min_score;

  //restore best mode's prediction from cache
  pixel_load_4x4(prediction + BLOCK_OFFSET_4[n], pred4_cache[result], I4x4CACHE_STRIDE);
end;


function TIntraPredictor.Analyse_8x8_chroma(refU, refV: pbyte): integer;
var
  mscore, cscore, mby, mbx: integer;
  cmp: mbcmp_func_t;
  mode: integer;

procedure ipmode(m: byte);
begin
  cscore := cmp (pixels_c[0], prediction_c[0], 16);
  cscore += cmp (pixels_c[1], prediction_c[1], 16);
  if cscore < mscore then begin
      mode := m;
      mscore := cscore;
  end;
end;

begin
  mscore := MaxInt;
  cmp := mbcmp_8x8;
  mbx := mb^.x;
  mby := mb^.y;

  //dc
  predict_dc8   (refU, prediction_c[0], stride_c, mbx, mby);
  predict_dc8   (refV, prediction_c[1], stride_c, mbx, mby);
  ipmode(INTRA_PRED_CHROMA_DC);

  //top - vertical
  if (mby > 0) then begin
      predict_top8  (refU, prediction_c[0], stride_c);
      predict_top8  (refV, prediction_c[1], stride_c);
      ipmode(INTRA_PRED_CHROMA_TOP);
  end;

  //left - horizontal
  if (mbx > 0) then begin
      predict_left8 (refU, prediction_c[0], stride_c);
      predict_left8 (refV, prediction_c[1], stride_c);
      ipmode(INTRA_PRED_CHROMA_LEFT);
  end;

  //plane
  if (mbx > 0) and (mby > 0) then begin
      predict_plane8(refU, prediction_c[0], stride_c);
      predict_plane8(refV, prediction_c[1], stride_c);
      ipmode(INTRA_PRED_CHROMA_PLANE);
  end;

  //restore best mode
  if mode <> INTRA_PRED_CHROMA_PLANE then
      Predict_8x8_chroma(mode, refU, refV, mbx, mby);
  result := mode;
end;


function TIntraPredictor.Analyse_16x16(): integer;
var
  mscore, cscore, mbx, mby: integer;
  cmp: mbcmp_func_t;
  mode: integer;

procedure ipmode(m: byte);
begin
  cscore := cmp(pixels, prediction, 16);
  if cscore < mscore then begin
      mode := m;
      mscore := cscore;
  end;
end;

begin
  mscore := MaxInt;
  cmp := mbcmp_16x16;
  mbx := mb^.x;
  mby := mb^.y;

  //vertical
  if (mby > 0) then begin
      predict_top16(pixel_cache, prediction);
      ipmode(INTRA_PRED_TOP);
  end;
  //horizontal
  if (mbx > 0) then begin
      predict_left16(pixel_cache, prediction);
      ipmode(INTRA_PRED_LEFT);
  end;
  //dc
  predict_dc16(pixel_cache, prediction, mbx, mby);
  ipmode(INTRA_PRED_DC);
  //plane
  if (mbx > 0) and (mby > 0) then begin
      predict_plane16(pixel_cache, prediction);
      ipmode(INTRA_PRED_PLANE);
  end;

  LastScore := mscore;
  result := mode;
end;




(*******************************************************************************
*)
{$ifdef CPUI386}
procedure predict_top16_sse2(src, dst: PUint8); cdecl; external;
procedure predict_left16_mmx(src, dst: PUint8); cdecl; external;
procedure predict_plane16_sse2(src, dst: PUint8); cdecl; external;
{$endif}
{$ifdef CPUX86_64}
procedure predict_top16_sse2(src, dst: PUint8); external name 'predict_top16_sse2';
procedure predict_left16_ssse3(src, dst: PUint8); external name 'predict_left16_ssse3';
procedure predict_plane16_sse2(src, dst: PUint8); external name 'predict_plane16_sse2';
procedure predict_dc16_ssse3(src, dst: PUint8; mbx, mby: longword); external name 'predict_dc16_ssse3';
{$endif}

procedure intra_pred_init(const flags: TDsp_init_flags);
begin
  predict_top16   := @predict_top16_pas;
  predict_left16  := @predict_left16_pas;
  predict_dc16    := @predict_dc16_pas;
  predict_plane16 := @predict_plane16_pas;

  {$ifdef CPUI386}
  if flags.sse2 then begin
      predict_top16   := @predict_top16_sse2;
      predict_plane16 := @predict_plane16_sse2;
  end;
  {$endif}
  {$ifdef CPUX86_64}
  if flags.sse2 then begin
      predict_top16   := @predict_top16_sse2;
      predict_plane16 := @predict_plane16_sse2;
  end;
  if flags.ssse3 then begin
      predict_left16  := @predict_left16_ssse3;
      predict_dc16    := @predict_dc16_ssse3;
  end;
  {$endif}
end;

end.

