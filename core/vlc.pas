(*******************************************************************************
vlc.pas
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

unit vlc;
{$mode objfpc}

interface

uses
  stdint, common, bitstream, h264tables;

type
  residual_type_t = (RES_LUMA := 0, RES_LUMA_DC, RES_LUMA_AC, RES_DC, RES_AC_U, RES_AC_V);

procedure vlc_init();
procedure vlc_done();

procedure cavlc_encode
  (const mb: macroblock_t; const blok: block_t; const blk_idx: byte; const res: residual_type_t; var bs: TBitstreamWriter);
function cavlc_block_bits
  (const mb: macroblock_t; const blok: block_t; const blk_idx: byte; const res: residual_type_t): integer;
procedure cavlc_analyse_block (var block: block_t; dct_coefs: int16_p; const ncoef: integer);
procedure cavlc_analyse_block_2x2(var block: block_t; dct_coefs: int16_p);

procedure write_se_code(var bs: TBitstreamWriter; n: integer);
procedure write_ue_code(var bs: TBitstreamWriter; const n: integer);
function  se_code_len(n: integer): integer;
function  ue_code_len(const n: integer): integer;


(*******************************************************************************
*******************************************************************************)
implementation

{ zigzag16 pattern
0:    1  2  6  7
4:    3  5  8 13
8:    4  9 12 14
12:  10 11 15 16
}

var
  ue_code_length_table: pbyte;
  se_code_length_table: pbyte;

const
  //maximum number (in absolute value) that can be exp-golomb encoded
  VLC_MAX_INT  = EG_MAX_ABS;
  VLC_TAB_SIZE = VLC_MAX_INT * 2 + 1;

(*******************************************************************************
calculate exp-golomb vlc code length table
*)
procedure vlc_init();
var
  bits, n,
  min, max: integer;

begin
  ue_code_length_table := getmem(VLC_TAB_SIZE);
  se_code_length_table := getmem(VLC_TAB_SIZE);
  se_code_length_table += VLC_MAX_INT;

  min := 1;
  max := 2;
  for bits := 1 to 12 do begin
      for n := min to (max - 1) do
         ue_code_length_table[n-1] := bits * 2 - 1;
      min := min shl 1;
      max := max shl 1;
  end;

  for n := -VLC_MAX_INT to VLC_MAX_INT do begin
      if n < 1 then
          se_code_length_table[n] := ue_code_length_table[-2 * n]
      else
          se_code_length_table[n] := ue_code_length_table[2 * n - 1];
  end;
end;


procedure vlc_done();
begin
  freemem(ue_code_length_table);
  se_code_length_table -= VLC_MAX_INT;
  freemem(se_code_length_table);
end;



(*******************************************************************************
vlc writing: signed and unsigned exp-golomb codes
*)
procedure write_se_code(var bs: TBitstreamWriter; n: integer);
begin
  if n < 1 then
      n := -2 * n
  else
      n := 2 * n - 1;
  assert(n < VLC_TAB_SIZE, 'vlc code exceeds range');
  bs.Write(n + 1, ue_code_length_table[n]);
end;


procedure write_ue_code(var bs: TBitstreamWriter; const n: integer);
begin
  bs.Write(n + 1, ue_code_length_table[n]);
end;


function se_code_len(n: integer): integer;
begin
  result := se_code_length_table[n];
end;

function ue_code_len(const n: integer): integer;
begin
  result := ue_code_length_table[n];
end;


procedure zigzag16(a, b: int16_p);
begin
  //for i := 0 to 15 do  a[i] := b[ zigzag_pos[i] ];
  a[0] := b[0];
  a[1] := b[1];
  a[2] := b[4];
  a[3] := b[8];
  a[4] := b[5];
  a[5] := b[2];
  a[6] := b[3];
  a[7] := b[6];
  a[8] := b[9];
  a[9] := b[12];
  a[10] := b[13];
  a[11] := b[10];
  a[12] := b[7];
  a[13] := b[11];
  a[14] := b[14];
  a[15] := b[15];
end;

procedure zigzag15(a, b: int16_p);
begin
  //for i := 0 to 14 do  a[i] := b[-1 + zigzag_pos[i+1]];
  a[0] := b[0];
  a[1] := b[3];
  a[2] := b[7];
  a[3] := b[4];
  a[4] := b[1];
  a[5] := b[2];
  a[6] := b[5];
  a[7] := b[8];
  a[8] := b[11];
  a[9] := b[12];
  a[10] := b[9];
  a[11] := b[6];
  a[12] := b[10];
  a[13] := b[13];
  a[14] := b[14];
end;


//get table index according to nz counts of surrounding blocks
function predict_nz_count_to_tab(const nzc: array of byte; const i: byte; const chroma: boolean = false): byte;
const
  { values:
    0..15  - current mb index
    16..19 - top mb, bottom row
    20..23 - left mb, rightmost column

    index: 0 - top/a, 1 - left/b
  }
  idx: array[0..15, 0..1] of byte = (
    (16, 20), (17,  0), ( 0, 21), ( 1,  2),
    (18,  1), (19,  4), ( 4,  3), ( 5,  6),
    ( 2, 22), ( 3,  8), ( 8, 23), ( 9, 10),
    ( 6,  9), ( 7, 12), (12, 11), (13, 14)
  );
  { 0..3 - current
    4, 5 - top mb, lower row
    6, 7 - left mb, right column
  }
  idxc: array[0..3, 0..1] of byte = (
    (4, 6), (5, 0),
    (0, 7), (1, 2)
  );

  nz2tab: array[0..16] of byte = (0,0,1,1,2,2,2,2,3,3,3,3,3,3,3,3,3);
var
  a, b, nc: byte;
begin
  if not chroma then begin
      a := nzc[ idx[i, 0] ];
      b := nzc[ idx[i, 1] ];
  end else begin
      a := nzc[ idxc[i, 0] ];
      b := nzc[ idxc[i, 1] ];
  end;
  if (a = NZ_COEF_CNT_NA) and (b = NZ_COEF_CNT_NA) then
      nc := 0
  else if a = NZ_COEF_CNT_NA then nc := b
  else if b = NZ_COEF_CNT_NA then nc := a
  else
      nc := (a + b + 1) shr 1;

  result := nz2tab[nc];
end;


{
9.2.2 Parsing process for level information
7 tables for sufflen range 0..6 according to JVT-E146 / JVT-D034 - sample code for VLC1-6
}
procedure encode_level(var bs: TBitstreamWriter; const level, suflen: integer);
var
  code: integer;
  levabs, sign, shift, escape, prefix, suffix, length, bits: integer;
begin
  Assert(suflen <= 6, '[encode_level] unsupported suffix length!');
  Assert(level <> 0, '[encode_level]: can''t encode level = 0!');

  //Lev-VLC 0
  if suflen = 0 then begin
      code := (abs(level) - 1) * 2;
      if level < 0 then code += 1;
      if code < 14 then begin
          bs.Write(1, code + 1);  //abs(1..7)
      end else begin
          if code < 30 then begin
              bs.Write(1, 15);  //escape short - abs(8..15)
              bs.Write(code - 14, 4);
          end else begin
              bs.Write(1, 16);  //escape long - abs(16..)
              bs.Write(code - 30, 12);
          end;
      end;
  end else begin
  //Lev-VLC 1-6
      levabs := abs(level);
      sign   := (level shr 31) and 1;
      shift  := suflen - 1;
      escape := (15 shl shift) + 1;
      prefix := (levabs - 1) shr shift;
      suffix := (levabs - 1) - (prefix shl shift);

      if levabs < escape then begin
          length := prefix + suflen + 1;
          bits   := (1 shl (shift + 1)) or (suffix shl 1) or sign;
      end else begin
          length := 28;
          bits   := (1 shl 12) or ((levabs - escape) shl 1) or sign;
      end;

      bs.Write(bits, length);
  end;
end;



(*******************************************************************************
cavlc_encode
*)
procedure cavlc_encode
  (const mb: macroblock_t; const blok: block_t; const blk_idx: byte; const res: residual_type_t; var bs: TBitstreamWriter);
var
  i: integer;
  coef: integer;
  run_before, zeros_left, total_zeros: integer;
  nz,               //TotalCoeff( coeff_token )
  t1: integer;      //TrailingOnes( coeff_token )

  tab: byte;
  suffix_length: byte;
  vlc: vlc_bits_len;


begin
  nz := blok.nlevel;
  t1 := blok.t1;

  //coef_token
  if res <> RES_DC then begin
      case res of
          RES_AC_U:
              tab := predict_nz_count_to_tab(mb.nz_coef_cnt_chroma_ac[0], blk_idx, true);
          RES_AC_V:
              tab := predict_nz_count_to_tab(mb.nz_coef_cnt_chroma_ac[1], blk_idx, true);
          //RES_LUMA, RES_LUMA_AC, RES_LUMA_DC:
          else
              tab := predict_nz_count_to_tab(mb.nz_coef_cnt, blk_idx);
      end;
      bs.Write(tab_coef_num[tab, nz, t1][0], tab_coef_num[tab, nz, t1][1])
  end else
      bs.Write(tab_coef_num_chroma_dc[nz, t1][0], tab_coef_num_chroma_dc[nz, t1][1]);

  if nz = 0 then //nothing more to write about
      exit;

  //trailing 1s signs
  for i := 0 to t1 - 1 do
      bs.Write((blok.t1_signs shr i) and 1);

  { 9.2.2 Parsing process for level information }
  //levels (nonzero coefs)
  if (nz > 10) and (t1 < 3) then
      suffix_length := 1
  else
      suffix_length := 0;

  for i := t1 to nz - 1 do begin
      coef := blok.level[i];

      //first coeff can't be |1| if t1 < 3, so we can code it as coeff lower by one
      if (i = t1) and (t1 < 3) then
          if coef > 0 then coef -= 1 else coef += 1;

      encode_level(bs, coef, suffix_length);

      if suffix_length = 0 then
          suffix_length := 1;
      if ( abs(blok.level[i]) > (3 shl (suffix_length - 1)) ) and (suffix_length < 6) then
          suffix_length += 1;
  end;

  //total number of zeros in runs
  total_zeros := blok.ncoef - nz - blok.t0;
  if nz < blok.ncoef then begin
      if res <> RES_DC then begin
          if nz < 8 then
              vlc := tab_total_zeros0[nz, total_zeros]
          else
              vlc := tab_total_zeros1[nz, total_zeros];
      end else
          vlc := tab_total_zeros_chroma_dc[nz, total_zeros];
      bs.Write(vlc[0], vlc[1]);
  end;

  //run_before
  if total_zeros > 0 then begin
      zeros_left := total_zeros;
      for i := 0 to nz - 2 do begin

           run_before := blok.run_before[i];
           if run_before < 7 then begin
               tab := zeros_left;
               if tab > 7 then tab := 7;
               bs.Write(tab_run_before[tab, run_before][0], tab_run_before[tab, run_before][1]);
           end else
               bs.Write(1, run_before - 3);

           zeros_left -= run_before;
           if zeros_left <= 0 then break;
      end;
  end;
end;


{*******************************************************************************
  bitcost functions
}
function level_cost(const level, suflen: integer): integer;
var
  code: integer;
  levabs, shift, escape, prefix: integer;
begin
  result := 0;
  //Lev-VLC 0
  if suflen = 0 then begin
      code := (abs(level) - 1) * 2;
      if level < 0 then code += 1;
      if code < 14 then begin
          result := code + 1;  //abs(1..7)
      end else begin
          if code < 30 then begin
              result := 19;
          end else begin
              result := 28;
          end;
      end;
  end else begin
  //Lev-VLC 1-6
      levabs := abs(level);
      shift  := suflen - 1;
      escape := (15 shl shift) + 1;
      prefix := (levabs - 1) shr shift;
      if levabs < escape then
          result := prefix + suflen + 1
      else
          result := 28;
  end;
end;


function cavlc_block_bits(const mb: macroblock_t; const blok: block_t; const blk_idx: byte; const res: residual_type_t): integer;
var
  i: integer;
  coef: integer;
  run_before, zeros_left, total_zeros: integer;
  nz, t1: integer;

  tab: byte;
  suffix_length: byte;
  vlc: vlc_bits_len;

begin
  result := 0;
  t1 := blok.t1;
  nz := blok.nlevel;

  //coef_token
  if res <> RES_DC then begin
      case res of
          RES_AC_U:
              tab := predict_nz_count_to_tab(mb.nz_coef_cnt_chroma_ac[0], blk_idx, true);
          RES_AC_V:
              tab := predict_nz_count_to_tab(mb.nz_coef_cnt_chroma_ac[1], blk_idx, true);
          else  //RES_LUMA, RES_LUMA_AC, RES_LUMA_DC:
              tab := predict_nz_count_to_tab(mb.nz_coef_cnt, blk_idx);
      end;
      result += tab_coef_num[tab, nz, t1][1];
  end else
      result += tab_coef_num_chroma_dc[nz, t1][1];
  if nz = 0 then exit;  //no coefs

  //trailing 1s signs
  result += t1;

  { 9.2.2 Parsing process for level information }
  //levels (nonzero coefs)
  if (nz > 10) and (t1 < 3) then
      suffix_length := 1
  else
      suffix_length := 0;

  for i := t1 to nz - 1 do begin
      coef := blok.level[i];

      //first coeff can't be |1| if t1 < 3, so we can code it as coeff lower by one
      if (i = t1) and (t1 < 3) then
          if coef > 0 then coef -= 1 else coef += 1;

      result += level_cost(coef, suffix_length);

      if suffix_length = 0 then
          suffix_length := 1;
      if ( abs(blok.level[i]) > (3 shl (suffix_length - 1)) ) and (suffix_length < 6) then
          suffix_length += 1;
  end;

  //total number of zeros in runs
  total_zeros := blok.ncoef - nz - blok.t0;
  if nz < blok.ncoef then begin
      if res <> RES_DC then begin
          if nz < 8 then
              vlc := tab_total_zeros0[nz, total_zeros]
          else
              vlc := tab_total_zeros1[nz, total_zeros];
      end else
          vlc := tab_total_zeros_chroma_dc[nz, total_zeros];
      result += vlc[1];
  end;

  //run_before
  if total_zeros > 0 then begin
      zeros_left := total_zeros;
      for i := 0 to nz - 2 do begin

           run_before := blok.run_before[i];
           if run_before < 7 then begin
               tab := zeros_left;
               if tab > 7 then tab := 7;
               result += tab_run_before[tab, run_before][1];
           end else
               result += run_before - 3;

           zeros_left -= run_before;
           if zeros_left <= 0 then break;
      end;
  end;
end;


//******************************************************************************
procedure cavlc_analyse_block (var block: block_t; dct_coefs: int16_p; const ncoef: integer);
var
  i, first_nz_index, zeros, n: integer;
  p: array[0..15] of int16_t;
  coef: integer;
  count_t1: boolean;
begin
  block.ncoef := ncoef;
  block.nlevel := 0;
  block.t1 := 0;

  //skip empty residual
  if pint64(dct_coefs)^ or pint64(dct_coefs+4)^ or pint64(dct_coefs+8)^ or pint64(dct_coefs+12)^ = 0 then
      exit;

  if ncoef = 16 then
      zigzag16(p, dct_coefs)
  else
      zigzag15(p, dct_coefs + 1);

  first_nz_index := ncoef - 1;
  while p[first_nz_index] = 0 do
      first_nz_index -= 1;

  block.t0 := ncoef - (first_nz_index+1);
  block.t1_signs := 0;

  n := 0;      //index for nonzero values
  zeros := 0;  //length of zero runs before nonzero
  count_t1 := true;

  for i := first_nz_index downto 0 do begin
      coef := p[i];
      if coef = 0 then begin
          zeros += 1;
      end else begin
          block.level[n] := coef;   //store coef, if it's a t1, then store the sign separately

          //trailing 1s
          if count_t1 and (block.t1 < 3) and (abs(coef) = 1) then begin
              if coef < 0 then
                  block.t1_signs := block.t1_signs or (1 shl block.t1);
              block.t1 += 1;
          end else
              count_t1 := false;

          if n > 0 then
              block.run_before[n-1] := zeros;  //save run_before
          zeros := 0;
          n += 1;
      end;
  end;
  if n < 16 then
      block.run_before[n-1] := zeros;
  block.nlevel := n;
end;


procedure cavlc_analyse_block_2x2(var block: block_t; dct_coefs: int16_p);
var
  p: array[0..3] of int16_t;
  i, zeros, n: integer;
  coef: integer;
  count_t1: boolean;
begin
  pint64(@p)^ := pint64(dct_coefs)^;
  block.ncoef := 4;
  block.nlevel := 0;
  block.t1 := 0;

  if pint64(@p)^ = 0 then
      exit;

  block.t1_signs := 0;

  n := 0;      //index for nonzero values
  zeros := 0;  //length of zero runs before nonzero
  count_t1 := true;

  for i := 3 downto 0 do begin
      coef := p[i];
      if coef = 0 then begin
          zeros += 1;
      end else begin
          block.level[n] := coef;   //store coef, if it's a t1, then store the sign separately

          //trailing 1s
          if count_t1 and (block.t1 < 3) and (abs(coef) = 1) then begin
              if coef < 0 then
                  block.t1_signs := block.t1_signs or (1 shl block.t1);
              block.t1 += 1;
          end else
              count_t1 := false;

          if n > 0 then
              block.run_before[n-1] := zeros  //save run_before
          else
              block.t0 := zeros;              //empty blocks never enter this loop, so it's always set
          zeros := 0;
          n += 1;
      end;
  end;
  block.run_before[n-1] := zeros;
  block.nlevel := n;
end;


(*******************************************************************************
*******************************************************************************)
initialization
vlc_init();

finalization
vlc_done();

end.
               
