(*******************************************************************************
pixel.pas
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

unit pixel;
{$mode objfpc}

interface

uses
  stdint, util;

procedure pixel_load_4x4 (dest, src: uint8_p; stride: integer);
procedure pixel_save_4x4 (src, dest: uint8_p; stride: integer);

procedure pixel_init(const flags: TDsp_init_flags);

var
  sad_16x16,
  sad_8x8,
  sad_4x4,
  ssd_16x16,
  ssd_8x8,
  satd_4x4,
  satd_8x8,
  satd_16x16: mbcmp_func_t;
  var_16x16: mbstat_func_t;
  pixel_load_16x16,
  pixel_loadu_16x16,
  pixel_load_8x8,
  pixel_save_16x16,
  pixel_save_8x8: pixmove_func_t;
  pixel_add_4x4,
  pixel_sub_4x4: pixoper_func_t;
  pixel_avg_16x16: pixavg_func_t;



(*******************************************************************************
*******************************************************************************)
implementation


function sad_16x16_pas (pix1, pix2: pbyte; stride: integer): integer; {$ifdef CPUI386} cdecl; {$endif}
var
  x, y: integer;
begin
  result := 0;
  for y := 0 to 15 do begin
      for x := 0 to 15 do
          result += abs(pix1[x] - pix2[x]);
      pix1 += 16;
      pix2 += stride;
  end;
end;


function sad_8x8_pas (pix1, pix2: pbyte; stride: integer): integer; {$ifdef CPUI386} cdecl; {$endif}
var
  x, y: integer;
begin
  result := 0;
  for y := 0 to 7 do begin
      for x := 0 to 7 do
          result += abs(pix1[x] - pix2[x]);
      pix1 += 16;
      pix2 += stride;
  end;
end;


function sad_4x4_pas (pix1, pix2: pbyte; stride: integer): integer; {$ifdef CPUI386} cdecl; {$endif}
var
  x, y: integer;
begin
  result := 0;
  for y := 0 to 3 do begin
      for x := 0 to 3 do
          result += abs(pix1[x] - pix2[x]);
      pix1 += 16;
      pix2 += stride;
  end;
end;



(*******************************************************************************
SSD
*)
function ssd_16x16_pas (pix1, pix2: pbyte; stride: integer): integer;{$ifdef CPUI386} cdecl; {$endif}
var
  x, y: integer;
begin
  result := 0;
  for y := 0 to 15 do begin
      for x := 0 to 15 do
          result += (pix1[x] - pix2[x]) * (pix1[x] - pix2[x]);
      pix1 += 16;
      pix2 += stride;
  end;
end;


function ssd_8x8_pas (pix1, pix2: pbyte; stride: integer): integer;{$ifdef CPUI386} cdecl; {$endif}
var
  x, y: integer;
begin
  result := 0;
  for y := 0 to 7 do begin
      for x := 0 to 7 do
          result += (pix1[x] - pix2[x]) * (pix1[x] - pix2[x]);
      pix1 += 16;
      pix2 += stride;
  end;
end;


(*******************************************************************************
variance 16x16
*)
function var_16x16_pas (pix: pbyte): uint32; {$ifdef CPUI386} cdecl; {$endif}
var
  x, y: integer;
  sum: longword;
  sqr: longword;
begin
  sum := 0;
  sqr := 0;
  for y := 0 to 15 do begin
      for x := 0 to 15 do begin
          sum += pix[x];
          sqr += pix[x] * pix[x];
      end;
      pix += 16;
  end;
  sum := (sum * sum) >> 8;
  result := sqr - sum;
end;



(*******************************************************************************
SATD
*)
function satd_4x4_pas(pix1, pix2: pbyte; stride: integer): integer; {$ifdef CPUI386} cdecl; {$endif}
type
  matrix_t = array[0..3, 0..3] of smallint;
var
  a, t: matrix_t;
  e, f, g, h: array[0..3] of smallint;
  i, j: integer;
begin
  for i := 0 to 3 do begin
      for j := 0 to 3 do
          a[i][j] := pix1[j] - pix2[j];
      pix1 += 16;
      pix2 += stride;
  end;

  for i := 0 to 3 do begin
      e[i] := a[0][i] + a[2][i];
      f[i] := a[0][i] - a[2][i];
      g[i] := a[1][i] + a[3][i];
      h[i] := a[1][i] - a[3][i];

      t[i][0] := e[i] + g[i];
      t[i][1] := e[i] - g[i];
      t[i][2] := f[i] + h[i];
      t[i][3] := f[i] - h[i];
  end;

  for i := 0 to 3 do begin
      e[i] := t[0][i] + t[2][i];
      f[i] := t[0][i] - t[2][i];
      g[i] := t[1][i] + t[3][i];
      h[i] := t[1][i] - t[3][i];
  end;
  for i := 0 to 3 do begin
      t[i][0] := e[i] + g[i];
      t[i][1] := e[i] - g[i];
      t[i][2] := f[i] + h[i];
      t[i][3] := f[i] - h[i];
  end;

  result := 0;
  for i := 0 to 15 do result += abs( psmallint(@t)[i] );
end;


function satd_8x8_pas(pix1, pix2: pbyte; stride: integer): integer; {$ifdef CPUI386} cdecl; {$endif}
var
  i: integer;
begin
  result := 0;
  for i := 0 to 1 do begin
      result += satd_4x4_pas(pix1,      pix2,      stride);
      result += satd_4x4_pas(pix1 +  4, pix2 +  4, stride);
      pix1 += 4 * 16;
      pix2 += 4 * stride;
  end
end;


function satd_16x16_pas(pix1, pix2: pbyte; stride: integer): integer; {$ifdef CPUI386} cdecl; {$endif}
var
  i: integer;
begin
  result := 0;
  for i := 0 to 3 do begin
      result += satd_4x4_pas(pix1,      pix2,      stride);
      result += satd_4x4_pas(pix1 +  4, pix2 +  4, stride);
      result += satd_4x4_pas(pix1 +  8, pix2 +  8, stride);
      result += satd_4x4_pas(pix1 + 12, pix2 + 12, stride);
      pix1 += 4 * 16;
      pix2 += 4 * stride;
  end
end;


(*******************************************************************************
pixel_sub_8x8_pas
subtract two 8x8 blocks, return word-sized results
*)
procedure pixel_sub_4x4_pas (pix1, pix2: pbyte; diff: int16_p); {$ifdef CPUI386} cdecl; {$endif}
var
  x, y: integer;
begin
  for y := 0 to 3 do begin
      for x := 0 to 3 do
          diff[x] := pix1[x] - pix2[x];
      pix1 += 16;
      pix2 += 16;
      diff +=  4;
  end;
end;


(*******************************************************************************
pixel_add_8x8_pas
addition of two 8x8 blocks, return clipped byte-sized results
*)
procedure pixel_add_4x4_pas (pix1, pix2: pbyte; diff: int16_p); {$ifdef CPUI386} cdecl; {$endif}

function clip (c: integer): byte; inline;
begin
    result := byte (c);
    if c > 255 then
        Result := 255
    else
        if c < 0 then result := 0;
end;

var
  y, x: integer;
begin
  for y := 0 to 3 do begin
      for x := 0 to 3 do
          pix1[x] := clip( diff[x] + pix2[x] );
      pix1 += 16;
      pix2 += 16;
      diff +=  4;
  end;
end;


(*******************************************************************************
pixel_load_16x16
load 16x16 pixel block from frame
*)
procedure pixel_load_16x16_pas (dest, src: uint8_p; stride: integer); {$ifdef CPUI386} cdecl; {$endif}
var
  i: integer;
begin
  for i := 0 to 15 do begin
      move(src^, dest^, 16);
      src  += stride;
      dest += 16;
  end;
end;


procedure pixel_load_8x8_pas (dest, src: uint8_p; stride: integer); {$ifdef CPUI386} cdecl; {$endif}
var
  i: integer;
begin
  for i := 0 to 7 do begin
      uint64_p(dest)^ := uint64_p(src)^;
      src  += stride;
      dest += 16;
  end;
end;


procedure pixel_load_4x4 (dest, src: uint8_p; stride: integer);
var
  i: integer;
begin
  for i := 0 to 3 do begin
      uint32_p(dest)^ := uint32_p(src)^;
      src  += stride;
      dest += 16;
  end;
end;



(*******************************************************************************
pixel_save_16x16
save 16x16 pixel block to frame
*)
procedure pixel_save_16x16_pas (src, dest: uint8_p; stride: integer); {$ifdef CPUI386} cdecl; {$endif}
var
  i: integer;
begin
  for i := 0 to 15 do begin
      move(src^, dest^, 16);
      dest += stride;
      src  += 16;
  end;
end;


procedure pixel_save_8x8_pas(src, dest: uint8_p; stride: integer); {$ifdef CPUI386} cdecl; {$endif}
var
  i: integer;
begin
  for i := 0 to 7 do begin
      uint64_p(dest)^ := uint64_p(src)^;
      dest += stride;
      src  += 16;
  end;
end;


procedure pixel_save_4x4(src, dest: uint8_p; stride: integer);
var
  i: integer;
begin
  for i := 0 to 3 do begin
      uint32_p(dest)^ := uint32_p(src)^;
      dest += stride;
      src  += 16;
  end;
end;



(*******************************************************************************
pixel_avg_16x16
average of 2 pixel arrays
*)
procedure pixel_avg_16x16_pas(src1, src2, dest: uint8_p; stride: integer); {$ifdef CPUI386} cdecl; {$endif}
var
  x, y: integer;
begin
  for y := 0 to 15 do begin
      for x := 0 to 15 do
          dest[x] := (src1[x] + src2[x] + 1) shr 1;
      src1 += stride;
      src2 += stride;
      dest += 16;
  end;
end;



(*******************************************************************************
init fn pointers
*)
{$ifdef CPUI386}
function sad_16x16_mmx (pix1, pix2: pbyte; stride: integer): integer; cdecl; external;
function sad_16x16_sse2 (pix1, pix2: pbyte; stride: integer): integer; cdecl; external;
function sad_8x8_mmx   (pix1, pix2: pbyte; stride: integer): integer; cdecl; external;
function sad_4x4_mmx   (pix1, pix2: pbyte; stride: integer): integer; cdecl; external;

function ssd_16x16_sse2(pix1, pix2: pbyte; stride: integer): integer; cdecl; external;
function ssd_8x8_sse2  (pix1, pix2: pbyte; stride: integer): integer; cdecl; external;
function var_16x16_sse2(pix: pbyte): uint32; cdecl; external;

procedure pixel_loadu_16x16_sse2(dest, src: uint8_p; stride: integer); cdecl; external;
procedure pixel_load_16x16_sse2 (dest, src: uint8_p; stride: integer); cdecl; external;
procedure pixel_load_8x8_mmx    (dest, src: uint8_p; stride: integer); cdecl; external;
procedure pixel_save_16x16_sse2 (src, dest: uint8_p; stride: integer); cdecl; external;
procedure pixel_save_8x8_mmx    (src, dest: uint8_p; stride: integer); cdecl; external;

procedure pixel_sub_4x4_mmx (pix1, pix2: pbyte; diff: int16_p); cdecl; external;
procedure pixel_add_4x4_mmx (pix1, pix2: pbyte; diff: int16_p); cdecl; external;
procedure pixel_avg_16x16_sse2 (src1, src2, dest: uint8_p; stride: integer); cdecl; external;

function satd_16x16_sse2 (pix1, pix2: pbyte; stride: integer): integer; cdecl; external;
function satd_16x16_mmx (pix1, pix2: pbyte; stride: integer): integer; cdecl; external;
function satd_8x8_mmx   (pix1, pix2: pbyte; stride: integer): integer; cdecl; external;
function satd_4x4_mmx   (pix1, pix2: pbyte; stride: integer): integer; cdecl; external;
{$endif}

{$ifdef CPUX86_64}
function sad_16x16_sse2 (pix1, pix2: pbyte; stride: integer): integer; external name 'sad_16x16_sse2';
function sad_8x8_mmx   (pix1, pix2: pbyte; stride: integer): integer;  external name 'sad_8x8_mmx';
function sad_4x4_mmx   (pix1, pix2: pbyte; stride: integer): integer;  external name 'sad_4x4_mmx';

function ssd_16x16_sse2(pix1, pix2: pbyte; stride: integer): integer;  external name 'ssd_16x16_sse2';
function ssd_8x8_sse2  (pix1, pix2: pbyte; stride: integer): integer;  external name 'ssd_8x8_sse2';

function satd_16x16_sse2 (pix1, pix2: pbyte; stride: integer): integer; external name 'satd_16x16_sse2';
function satd_8x8_mmx   (pix1, pix2: pbyte; stride: integer): integer;  external name 'satd_8x8_mmx';
function satd_4x4_mmx   (pix1, pix2: pbyte; stride: integer): integer;  external name 'satd_4x4_mmx';

function var_16x16_sse2(pix: pbyte): uint32; external name 'var_16x16_sse2';

procedure pixel_loadu_16x16_sse2(dest, src: uint8_p; stride: integer); external name 'pixel_loadu_16x16_sse2';
procedure pixel_load_16x16_sse2 (dest, src: uint8_p; stride: integer); external name 'pixel_load_16x16_sse2';
procedure pixel_load_8x8_mmx    (dest, src: uint8_p; stride: integer); external name 'pixel_load_8x8_mmx';
procedure pixel_save_16x16_sse2 (src, dest: uint8_p; stride: integer); external name 'pixel_save_16x16_sse2';
procedure pixel_save_8x8_mmx    (src, dest: uint8_p; stride: integer); external name 'pixel_save_8x8_mmx';

procedure pixel_sub_4x4_mmx (pix1, pix2: pbyte; diff: int16_p); external name 'pixel_sub_4x4_mmx';
procedure pixel_add_4x4_mmx (pix1, pix2: pbyte; diff: int16_p); external name 'pixel_add_4x4_mmx';
procedure pixel_avg_16x16_sse2 (src1, src2, dest: uint8_p; stride: integer); external name 'pixel_avg_16x16_sse2';
{$endif}

procedure pixel_init(const flags: TDsp_init_flags);
begin
  sad_16x16 := @sad_16x16_pas;
  sad_8x8   := @sad_8x8_pas;
  sad_4x4   := @sad_4x4_pas;

  ssd_16x16 := @ssd_16x16_pas;
  ssd_8x8   := @ssd_8x8_pas;
  var_16x16 := @var_16x16_pas;

  satd_4x4   := @satd_4x4_pas;
  satd_8x8   := @satd_8x8_pas;
  satd_16x16 := @satd_16x16_pas;

  pixel_load_16x16  := @pixel_load_16x16_pas;
  pixel_loadu_16x16 := @pixel_load_16x16_pas;
  pixel_load_8x8   := @pixel_load_8x8_pas;
  pixel_save_16x16 := @pixel_save_16x16_pas;
  pixel_save_8x8   := @pixel_save_8x8_pas;
  pixel_add_4x4    := @pixel_add_4x4_pas;
  pixel_sub_4x4    := @pixel_sub_4x4_pas;
  pixel_avg_16x16  := @pixel_avg_16x16_pas;

  {$ifdef CPUI386}
  if flags.mmx then begin
      sad_16x16 := @sad_16x16_mmx;
      sad_8x8   := @sad_8x8_mmx;
      sad_4x4   := @sad_4x4_mmx;
      satd_4x4   := @satd_4x4_mmx;
      satd_8x8   := @satd_8x8_mmx;
      satd_16x16 := @satd_16x16_mmx;

      pixel_load_8x8 := @pixel_load_8x8_mmx;
      pixel_save_8x8 := @pixel_save_8x8_mmx;
      pixel_add_4x4  := @pixel_add_4x4_mmx;
      pixel_sub_4x4  := @pixel_sub_4x4_mmx;
  end;

  if flags.sse2 then begin
      sad_16x16 := @sad_16x16_sse2;
      ssd_16x16 := @ssd_16x16_sse2;
      ssd_8x8   := @ssd_8x8_sse2;
      var_16x16 := @var_16x16_sse2;
      satd_16x16 := @satd_16x16_sse2;

      pixel_loadu_16x16 := @pixel_loadu_16x16_sse2;
      pixel_load_16x16 := @pixel_load_16x16_sse2;
      pixel_save_16x16 := @pixel_save_16x16_sse2;
      pixel_avg_16x16  := @pixel_avg_16x16_sse2;
  end;
  {$endif}

  {$ifdef CPUX86_64}
  //all 64bit sse2 cpus have mmx
  if flags.sse2 then begin
      sad_16x16 := @sad_16x16_sse2;
      sad_8x8   := @sad_8x8_mmx;
      sad_4x4   := @sad_4x4_mmx;
      ssd_16x16 := @ssd_16x16_sse2;
      ssd_8x8   := @ssd_8x8_sse2;

      satd_4x4   := @satd_4x4_mmx;
      satd_8x8   := @satd_8x8_mmx;
      satd_16x16 := @satd_16x16_sse2;

      var_16x16 := @var_16x16_sse2;

      pixel_loadu_16x16 := @pixel_loadu_16x16_sse2;
      pixel_load_16x16 := @pixel_load_16x16_sse2;
      pixel_save_16x16 := @pixel_save_16x16_sse2;
      pixel_load_8x8 := @pixel_load_8x8_mmx;
      pixel_save_8x8 := @pixel_save_8x8_mmx;

      pixel_add_4x4  := @pixel_add_4x4_mmx;
      pixel_sub_4x4  := @pixel_sub_4x4_mmx;
      pixel_avg_16x16  := @pixel_avg_16x16_sse2;
  end;
  {$endif}
end;

end.

