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
  stdint, common, util, pixel;

type

  { TIntraPredictor }

  TIntraPredictor = class
    public
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

      constructor Create;
      destructor Free;
      procedure UseSATDCompare;
      procedure Predict_4x4   (mode: integer; ref: pbyte; mbx, mby, n: integer);
      procedure Predict_8x8_cr(mode: integer; refU, refV: pbyte; mbx, mby: integer);
      procedure Predict_16x16 (mode: integer; mbx, mby: integer);

      //Get best mode for i4x4 prediction. Also stores the predicted pixels
      function Analyse_4x4(const ref: pbyte; const mbx, mby, n: integer): integer;

      procedure Analyse_8x8_cr(refU, refV: pbyte; mbx, mby: integer; out mode: integer);
      procedure Analyse_16x16 (mbx, mby: integer; out mode: integer; out score: integer);

    private
      mbcmp_16x16,
      mbcmp_8x8,
      mbcmp_4x4: mbcmp_func_t;
      pred4_cache: array[0..8] of pbyte;  //cache for 4x4 predicted pixels
  end;

var
  predict_top16,
  predict_left16,
  predict_plane16: procedure (src, dst: uint8_p); {$ifdef CPUI386} cdecl; {$endif}

procedure intra_pred_init(const flags: TDsp_init_flags);


(*******************************************************************************
*)
implementation

const
  I4x4CACHE_STRIDE = 16;

(* top *)
procedure predict_top4( src, dst: uint8_p; sstride: integer );
var
  p: int32_t;
  i: integer;
begin
  src -= sstride;
  p := int32_p(src)^;
  for i := 0 to 3 do begin
      int32_p(dst)^ := p;
      dst += I4x4CACHE_STRIDE;
  end;
end;


(* left *)
procedure predict_left4( src, dst: uint8_p; sstride: integer );
var
  i, p: integer;
begin
  src -= 1;
  for i := 0 to 3 do begin
      p := (src^ shl 8) or src^;
      int32_p(dst)^ := (p shl 16) or p;
      src += sstride;
      dst += I4x4CACHE_STRIDE;
  end;
end;


(* dc *)
procedure predict_dc4( src, dst: uint8_p; sstride: integer; mbx, mby, n: word);
var
  has_top, has_left: boolean;
  dc, i, shift: integer;
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
  dc := dc or (dc shl 8) or (dc shl 16) or (dc shl 24);  //spread

  for i := 0 to 3 do begin
      int32_p(dst)^ := dc;
      dst += I4x4CACHE_STRIDE;
  end;
end;


{ 8.3.1.2.4  Specification of Intra_4x4_Diagonal_Down_Left prediction mode
If x is equal to 3 and y is equal to 3,
  pred4x4L[x, y] = ( p[6, -1] + 3 * p[7, -1] + 2 ) >> 2
Otherwise (x is not equal to 3 or y is not equal to 3),
  pred4x4L[x, y] = ( p[x + y, -1] + 2 * p[x + y + 1, -1] + p[x + y + 2, -1] + 2 ) >> 2
}
procedure predict_ddl4( src, dst: uint8_p; sstride: integer );
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
procedure predict_ddr4( src, dst: uint8_p; sstride: integer );
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
procedure predict_vr4( src, dst: uint8_p; stride: integer );
var
  z, x, y, i: integer;
begin
  for x := 0 to 3 do
      for y := 0 to 3 do begin
          z := 2 * x - y;
          if z >= 0 then begin
              i := x - (y div 2) - stride;
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
procedure predict_vl4( src, dst: uint8_p; stride: integer );
var
  x, y: integer;
begin
  for x := 0 to 3 do
      for y := 0 to 3 do
          if (y and 1) = 1 then
              dst[x+y*I4x4CACHE_STRIDE] := (src[x + (y div 2)     - stride]
                            + src[x + (y div 2) + 1 - stride] * 2
                            + src[x + (y div 2) + 2 - stride] + 2) div 4
              //P[x,y] = (S[x+(y/2),-1] + 2 * S[x+(y/2)+1,-1] + S[x+(y/2)+2,-1] + 2) / 4
          else
              dst[x+y*I4x4CACHE_STRIDE] := (src[x + (y div 2)     - stride]
                            + src[x + (y div 2) + 1 - stride] + 1) div 2;
              //P[x,y] = (S[x+(y/2),-1] + S[x+(y/2)+1,-1] + 1) / 2
end;


(* horiz down *)
procedure predict_hd4( src, dst: uint8_p; stride: integer );
var
  z, x, y, i: integer;
begin
  for x := 0 to 3 do
      for y := 0 to 3 do begin
          z := 2 * y - x;
          if z >= 0 then begin
              i := y - (x div 2);
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
procedure predict_hu4( src, dst: uint8_p; stride: integer );
var
  z, x, y, i: integer;
begin
  for x := 0 to 3 do
      for y := 0 to 3 do begin
          z := x + 2 * y;
          if (z >= 0) and (z < 5) then begin
              i := y + (x div 2);
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
procedure predict_top16_pas(src, dst: uint8_p); {$ifdef CPUI386} cdecl; {$endif}
var
  p1, p2: int64_t;
  i: integer;
begin
  p1 := int64_p(src+1)^;
  p2 := int64_p(src+9)^;
  for i := 0 to 7 do begin
      int64_p(dst   )^ := p1;
      int64_p(dst+8 )^ := p2;
      int64_p(dst+16)^ := p1;
      int64_p(dst+24)^ := p2;
      dst += 32;
  end;
end;


procedure predict_left16_pas(src, dst: uint8_p); {$ifdef CPUI386} cdecl; {$endif}
var
  i: integer;
  v: int64;
begin
  src += 18;
  for i := 0 to 15 do begin
      v := (src^ shl 24) or (src^ shl 16) or (src^ shl 8) or src^;
      v := v or (v shl 32);
      int64_p(dst  )^ := v;
      int64_p(dst+8)^ := v;
      src += 1;
      dst += 16;
  end;
end;


procedure predict_dc16(src, dst: uint8_p; const mbx, mby: word);
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


procedure predict_plane16_pas(src, dst: uint8_p); {$ifdef CPUI386} cdecl; {$endif}
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
procedure predict_dc8( src, dst: uint8_p; sstride: integer; mbx, mby: word);
var
  has_top, has_left: boolean;
  i, k: integer;
  dc, shift: integer;
  dcf: array[0..3] of byte;

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
  for i := 0 to 3 do begin
      for k := 0 to 3 do
          dst[k] := dcf[0];
      for k := 4 to 7 do
          dst[k] := dcf[1];
      dst += 16;
  end;

  for i := 0 to 3 do begin
      for k := 0 to 3 do
          dst[k] := dcf[2];
      for k := 4 to 7 do
          dst[k] := dcf[3];
      dst += 16;
  end;
end;


procedure predict_top8( src, dst: uint8_p; sstride: integer );
var
  p: int64;
  i: integer;
begin
  src -= sstride;
  p := int64_p(src)^;
  for i := 0 to 7 do begin
      int64_p(dst)^ := p;
      dst += 16;
  end;
end;


procedure predict_left8( src, dst: uint8_p; sstride: integer );
var
  i, j: integer;
begin
  src -= 1;
  for i := 0 to 7 do begin
      for j := 0 to 7 do
          dst[j] := src^;
      src += sstride;
      dst += 16;
  end;
end;


procedure predict_plane8( src, dst: uint8_p; stride: integer);
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


procedure TIntraPredictor.Predict_4x4(mode: integer; ref: pbyte; mbx, mby, n: integer);
begin
  case mode of
      INTRA_PRED_DC:
          predict_dc4  (ref, prediction + block_offset4[n], frame_stride, mbx, mby, n);
      INTRA_PRED_TOP:
          predict_top4 (ref, prediction + block_offset4[n], frame_stride);
      INTRA_PRED_LEFT:
          predict_left4(ref, prediction + block_offset4[n], frame_stride);
      INTRA_PRED_DDL:
          predict_ddl4 (ref, prediction + block_offset4[n], frame_stride);
      INTRA_PRED_DDR:
          predict_ddr4 (ref, prediction + block_offset4[n], frame_stride);
      INTRA_PRED_VR:
          predict_vr4  (ref, prediction + block_offset4[n], frame_stride);
      INTRA_PRED_HD:
          predict_hd4  (ref, prediction + block_offset4[n], frame_stride);
      INTRA_PRED_VL:
          predict_vl4  (ref, prediction + block_offset4[n], frame_stride);
      INTRA_PRED_HU:
          predict_hu4  (ref, prediction + block_offset4[n], frame_stride);
  else
      writeln('mb_intra_pred_4 error: unknown predict mode');
  end;
end;


procedure TIntraPredictor.Predict_8x8_cr(mode: integer; refU, refV: pbyte; mbx, mby: integer);
begin
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
      end
  else
      writeln('mb_intra_pred_chroma error: unknown predict mode');
  end;
end;


procedure TIntraPredictor.Predict_16x16(mode: integer; mbx, mby: integer);
begin
  case mode of
      INTRA_PRED_DC:
          predict_dc16   (pixel_cache, prediction, mbx, mby);
      INTRA_PRED_TOP:
          predict_top16  (pixel_cache, prediction);
      INTRA_PRED_LEFT:
          predict_left16 (pixel_cache, prediction);
      INTRA_PRED_PLANE:
          predict_plane16(pixel_cache, prediction);
  else
      writeln('mb_intra_pred_16 error: unknown predict mode');
  end;
end;


function TIntraPredictor.Analyse_4x4(const ref: pbyte; const mbx, mby, n: integer): integer;
var
  pix: pbyte;
  min_score: integer;

procedure GetScore(const mode: integer); inline;
var
  score: integer;
begin
  score := mbcmp_4x4(pix, pred4_cache[mode], I4x4CACHE_STRIDE);
  if score < min_score then begin
      min_score := score;
      result := mode;
  end;
end;

begin
  pix := pixels + block_offset4[n];
  min_score := MaxInt;

  //dc
  predict_dc4( ref, pred4_cache[INTRA_PRED_DC], frame_stride, mbx, mby, n );
  GetScore(INTRA_PRED_DC);
  //top - vertical
  if (mby > 0) or not(n in [0, 1, 4, 5]) then begin
      predict_top4( ref, pred4_cache[INTRA_PRED_TOP], frame_stride );
      GetScore(INTRA_PRED_TOP);
  end;
  //left - horizontal
  if (mbx > 0) or not(n in [0, 2, 8, 10]) then begin
      predict_left4( ref, pred4_cache[INTRA_PRED_LEFT], frame_stride );
      predict_hu4  ( ref, pred4_cache[INTRA_PRED_HU], frame_stride );
      GetScore(INTRA_PRED_LEFT);
      GetScore(INTRA_PRED_HU);
  end;
  //top & left pixels
  if ((mbx > 0) and (mby > 0)) or (n in [3, 6, 7, 9, 11, 12, 13, 14, 15]) then begin
      predict_ddr4( ref, pred4_cache[INTRA_PRED_DDR], frame_stride );
      predict_vr4 ( ref, pred4_cache[INTRA_PRED_VR], frame_stride );
      predict_hd4 ( ref, pred4_cache[INTRA_PRED_HD], frame_stride );
      GetScore(INTRA_PRED_DDR);
      GetScore(INTRA_PRED_VR);
      GetScore(INTRA_PRED_HD);
  end;
  //top & top-right pixels
  if (mby > 0) and (mbx < mb_width - 1) and not(n in [3, 7, 11, 13, 15]) then begin
      predict_ddl4( ref, pred4_cache[INTRA_PRED_DDL], frame_stride );
      GetScore(INTRA_PRED_DDL);

      //left, top & top-right pixels
      if mbx > 0 then begin
          predict_vl4( ref, pred4_cache[INTRA_PRED_VL], frame_stride );
          GetScore(INTRA_PRED_VL);
      end;
  end;

  //load from cache
  pixel_load_4x4(prediction + block_offset4[n], pred4_cache[result], I4x4CACHE_STRIDE);
end;


procedure TIntraPredictor.Analyse_8x8_cr(refU, refV: pbyte; mbx, mby: integer; out mode: integer);
var
  mscore, cscore: integer;
  cmp: mbcmp_func_t;

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
  Predict_8x8_cr(mode, refU, refV, mbx, mby);
end;


procedure TIntraPredictor.Analyse_16x16(mbx, mby: integer; out mode: integer; out score: integer);
var
  mscore, cscore: integer;
  cmp: mbcmp_func_t;

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

  //dc
  predict_dc16(pixel_cache, prediction, mbx, mby);
  ipmode(INTRA_PRED_DC);

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

  //plane
  if (mbx > 0) and (mby > 0) then begin
      predict_plane16(pixel_cache, prediction);
      ipmode(INTRA_PRED_PLANE);
  end;

  score := mscore;
end;




(*******************************************************************************
*)
{$ifdef CPUI386}
procedure predict_top16_sse2(src, dst: uint8_p); cdecl; external;
procedure predict_left16_mmx(src, dst: uint8_p); cdecl; external;
procedure predict_plane16_sse2(src, dst: uint8_p); cdecl; external;
{$endif}
{$ifdef CPUX86_64}
procedure predict_top16_sse2(src, dst: uint8_p); external name 'predict_top16_sse2';
procedure predict_left16_mmx(src, dst: uint8_p); external name 'predict_left16_mmx';
procedure predict_plane16_sse2(src, dst: uint8_p); external name 'predict_plane16_sse2';
{$endif}

procedure intra_pred_init(const flags: TDsp_init_flags);
begin
  predict_top16   := @predict_top16_pas;
  predict_left16  := @predict_left16_pas;
  predict_plane16 := @predict_plane16_pas;

  {$ifdef CPUI386}
  if flags.mmx then begin
      predict_left16  := @predict_left16_mmx;
  end;
  if flags.sse2 then begin
      predict_top16   := @predict_top16_sse2;
      predict_plane16 := @predict_plane16_sse2;
  end;
  {$endif}
  {$ifdef CPUX86_64}
  if flags.sse2 then begin
      predict_top16   := @predict_top16_sse2;
      predict_left16  := @predict_left16_mmx;
      predict_plane16 := @predict_plane16_sse2;
  end;
  {$endif}
end;

end.

