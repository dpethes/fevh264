(*******************************************************************************
util.pas
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

unit util;

{$mode objfpc}{$H+}

interface

uses
  stdint, math;

function  fev_malloc (size: longword): pointer;
procedure fev_free (ptr: pointer);

function min(const a, b: integer): integer; inline;
function max(const a, b: integer): integer; inline;
function clip3(const a, b, c: integer): integer; inline;  //lower bound, value, upper bound
function median(const x, y, z: integer): int16;
function num2log2(n: integer): byte;
function clip(i: integer): byte;  //don't inline yet, as fpc seems to be unable to inline it in other units

procedure swap_ptr(var a, b: pointer);

type
mbcmp_func_t = function (pix1, pix2: pbyte; stride: integer): integer; {$ifdef CPUI386} cdecl; {$endif}
mbstat_func_t = function (pix: pbyte): uint32; {$ifdef CPUI386} cdecl; {$endif}
pixmove_func_t = procedure (pix1, pix2: pbyte; stride: integer); {$ifdef CPUI386} cdecl; {$endif}
pixoper_func_t = procedure (pix1, pix2: pbyte; diff: int16_p); {$ifdef CPUI386} cdecl; {$endif}
pixavg_func_t = procedure (src1, src2, dest: uint8_p; stride: integer); {$ifdef CPUI386} cdecl; {$endif}
pixdownsample_func_t = procedure (src: uint8_p; src_stride: integer; dst: uint8_p; dst_width: integer); {$ifdef CPUI386} cdecl; {$endif}
mc_chroma_func_t = procedure (src, dst: pbyte; const stride: integer; coef: pbyte); {$ifdef CPUI386} cdecl; {$endif}
core_xform_func_t = procedure (block: pInt16); {$ifdef CPUI386} cdecl; {$endif}
quant_func_t  = procedure(block: pInt16; mf: pInt16; f: integer; qbits: integer; starting_idx: integer); {$ifdef CPUI386} cdecl; {$endif}
iquant_func_t = procedure(block: pInt16; mf: pInt16; shift: integer; starting_idx: integer); {$ifdef CPUI386} cdecl; {$endif}

TDsp_init_flags = record
    mmx: boolean;
    sse2: boolean;
    ssse3: boolean;
    avx2: boolean;
end;

{ TDsp }
TDsp = class
  public
    sad_16x16,
    sad_8x8,
    sad_4x4,
    ssd_16x16,
    ssd_8x8,
    satd_4x4,
    satd_8x4,
    satd_8x8,
    satd_16x8,
    satd_16x16: mbcmp_func_t;
    var_16x16: mbstat_func_t;

    pixel_load_16x16,
    pixel_load_8x8,
    pixel_save_16x16,
    pixel_save_8x8: pixmove_func_t;
    pixel_add_4x4,
    pixel_sub_4x4: pixoper_func_t;
    pixel_avg_16x16: pixavg_func_t;
    pixel_avg_16x8: pixavg_func_t;
    pixel_downsample_row: pixdownsample_func_t;

    pixel_loadu_16x16: pixmove_func_t; //unaligned memory load
    pixel_loadu_16x8: pixmove_func_t;
    mc_chroma_8x8: mc_chroma_func_t;
    mc_chroma_8x4: mc_chroma_func_t;

    constructor Create(flags: TDsp_init_flags);
    procedure FpuReset;
end;

var dsp: TDsp;


(*******************************************************************************
*******************************************************************************)
implementation

uses
  pixel, motion_comp, transquant;


(*******************************************************************************
evx_malloc, evx_mfree
memory allocation with address aligned to 16-byte boundaries
*******************************************************************************)
function fev_malloc (size: longword): pointer;
const
  ALIGNMENT = 64;
var
  ptr: pointer;
begin
  ptr := getmem(size + ALIGNMENT);
  result := Align (ptr, ALIGNMENT);
  if result = ptr then
      pbyte(result) += ALIGNMENT;
  (pbyte(result) - 1)^ := result - ptr;
end;

procedure fev_free (ptr: pointer);
begin
  if ptr = nil then exit;
  pbyte(ptr) -= pbyte(ptr-1)^ ;
  freemem(ptr);
  ptr := nil;
end;


function min(const a, b: integer): integer;
begin
  if a < b then result := a
  else result := b;
end;

function max(const a, b: integer): integer;
begin
  if a >= b then result := a
  else result := b;
end;

function clip3(const a, b, c: integer): integer;
begin
  if b < a then result := a
  else if b > c then result := c
  else result := b;
end;

function median(const x, y, z: integer): int16;
begin
  result := x + y + z - min( x, min( y, z ) ) - max( x, max( y, z ) );
end;

function num2log2(n: integer): byte;
begin
  result := ceil( log2(n) );
end;

function clip(i: integer): byte;
begin
  if word(i) > 255 then result := byte(not(i >> 16))
  else result := byte(i);
end;

procedure swap_ptr(var a, b: pointer);
var
  t: pointer;
begin
  t := a;
  a := b;
  b := t;
end;


{ TDsp }

constructor TDsp.Create(flags: TDsp_init_flags);
begin
  pixel_init(flags);
  motion_compensate_init(flags);
  transquant_init(flags);

  sad_16x16 := pixel.sad_16x16;
  sad_8x8   := pixel.sad_8x8;
  sad_4x4   := pixel.sad_4x4;
  satd_16x16 := pixel.satd_16x16;
  satd_16x8  := pixel.satd_16x8;
  satd_8x8   := pixel.satd_8x8;
  satd_8x4   := pixel.satd_8x4;
  satd_4x4   := pixel.satd_4x4;
  ssd_16x16 := pixel.ssd_16x16;
  ssd_8x8   := pixel.ssd_8x8;
  var_16x16 := pixel.var_16x16;

  pixel_loadu_16x16 := pixel.pixel_loadu_16x16;
  pixel_loadu_16x8 := pixel.pixel_loadu_16x8;

  pixel_load_16x16 := pixel.pixel_load_16x16;
  pixel_load_8x8   := pixel.pixel_load_8x8;
  pixel_save_16x16 := pixel.pixel_save_16x16;
  pixel_save_8x8   := pixel.pixel_save_8x8;
  pixel_add_4x4  := pixel.pixel_add_4x4;
  pixel_sub_4x4  := pixel.pixel_sub_4x4;
  pixel_avg_16x16  := pixel.pixel_avg_16x16;
  pixel_avg_16x8  := pixel.pixel_avg_16x8;
  pixel_downsample_row := pixel.pixel_downsample_row;

  mc_chroma_8x8 := motion_comp.mc_chroma_8x8;
  mc_chroma_8x4 := motion_comp.mc_chroma_8x4;
end;

{$ifdef CPUI386} {$define X86_COMPAT} {$endif}
{$ifdef CPUX86_64} {$define X86_COMPAT} {$endif}
procedure TDsp.FpuReset;
begin
  {$ifdef X86_COMPAT}
  {$asmmode intel}
  asm
      emms
  end;
  {$endif}
end;


end.

