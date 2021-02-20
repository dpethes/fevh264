(*******************************************************************************
common.pas
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

unit common;
{$mode objfpc}
{$ModeSwitch advancedrecords}
//linked libs list
{$ifdef CPUI386}
  {$L asm/pixel_x86.o}
  {$L asm/frame_x86.o}
  {$L asm/intra_pred_x86.o}
  {$L asm/motion_comp_x86.o}
{$endif}
{$ifdef CPUX86_64}
  {$L asm_x64/pixel_x64.o}
  {$L asm_x64/motion_comp_x64.o}
  {$L asm_x64/frame_x64.o}
  {$L asm_x64/intra_pred_x64.o}
  {$L asm_x64/transquant_x64.o}
{$endif}

interface

uses
  stats;
  
const
  SLICE_P = 5;
  SLICE_I = 7;

  MB_I_4x4   = 0;
  MB_I_16x16 = 1;
  MB_P_16x16 = 2;
  MB_P_SKIP  = 3;
  MB_I_PCM   = 4;
  MB_P_16x8  = 5;

  INTRA_PRED_TOP   = 0;
  INTRA_PRED_LEFT  = 1;
  INTRA_PRED_DC    = 2;
  INTRA_PRED_PLANE = 3; //I16x16
  INTRA_PRED_DDL   = 3; //I4x4
  INTRA_PRED_DDR   = 4;
  INTRA_PRED_VR    = 5;
  INTRA_PRED_HD    = 6;
  INTRA_PRED_VL    = 7;
  INTRA_PRED_HU    = 8;
  INTRA_PRED_NA    = 255;

  INTRA_PRED_CHROMA_DC    = 0;
  INTRA_PRED_CHROMA_LEFT  = 1;
  INTRA_PRED_CHROMA_TOP   = 2;
  INTRA_PRED_CHROMA_PLANE = 3;

  NZ_COEF_CNT_NA = 255;

  EG_MAX_ABS = 2047; // = 2^12 / 2 - 1 (abs.maximum for exp-golomb encoding)
  MB_SKIP_MAX = EG_MAX_ABS * 2;

  MB_DCT_ARRAY_SIZE = 2 * 16 * 25;

  CBP_LUMA_MASK = %1111;

{ ordering of 8x8 luma blocks
  1 | 2
  --+--
  3 | 4

  ordering of 4x4 luma blocks
   0 |  1 |  4 |  5
  ---+----+----+---
   2 |  3 |  6 |  7
  ---+----+----+---
   8 |  9 | 12 | 13
  ---+----+----+---
  10 | 11 | 14 | 15
}
  BLOCK_OFFSET_4: array[0..15] of byte = (
       0,   4,  64,  68,
       8,  12,  72,  76,
     128, 132, 192, 196,
     136, 140, 200, 204
  );

{ ordering of 4x4 chroma blocks
  c0       c1
   0 | 1 |  | 0 | 1
  ---+---|  |-- +--
   2 | 3 |  | 2 | 3
}
  block_offset_chroma: array[0..3] of byte = (
       0,   4,
       64,  68
  );

  block_dc_order: array[0..15] of byte = (0, 1, 4, 5,  2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15);

type
  //motion vector
  motionvec_t = record
      x, y: int16;
  end;
  motionvec_p = ^motionvec_t;

  { TMotionVectorList }

  TMotionVectorList = record
    private
      mvs: array[0..12] of motionvec_t;
      function GetItem(i: byte): motionvec_t; inline;
    public
      Count: integer;
      procedure Add(const mv: motionvec_t);
      procedure Clear;
      property Items[i: byte]: motionvec_t read GetItem; Default;
  end;
  PMotionVectorList = ^TMotionVectorList;

  operator = (const a, b: motionvec_t): boolean; inline;
  operator / (const a: motionvec_t; const divisor: integer): motionvec_t; inline;
  operator * (const a: motionvec_t; const multiplier: integer): motionvec_t; inline;
  operator + (const a, b: motionvec_t): motionvec_t; inline;
  operator - (const a, b: motionvec_t): motionvec_t; inline;
  function XYToMVec(const x: integer; const y: integer): motionvec_t;

const
  ZERO_MV: motionvec_t = (x:0; y:0);

type
  frame_p = ^frame_t;

  //residual block
  block_t = record
       ncoef, nlevel: byte;
       t1, t1_signs: byte;
       t0: byte;
       run_before: array[0..14] of byte;
       level: array[0..15] of int16;
  end;

  //transquant function params cache
  TQuantCtx = record
      mult_factor,
      rescale_factor: pint16;
      f_intra, f_inter, f_dc: integer;
      qp_div6, qbits, qbits_dc: byte;
      qp: byte;  //just for correctness checks
  end;

  //boundary strength
  TBSarray = array[0..3, 0..3] of byte;

  //macroblock
  macroblock_p = ^macroblock_t;
  macroblock_t = record
      x, y: int16;            //position
      mbtype: int8;
      qp,
      qpc: byte;
      chroma_qp_offset: int8;

      i4_pred_mode: array[0..23] of UInt8;
                              { intra prediction mode for luma 4x4 blocks
                                0..15  - blocks from current mb
                                16..19 - top mb bottom row
                                20..23 - left mb right column
                              }
      i16_pred_mode: int8;    //intra 16x16 pred mode
      chroma_pred_mode: int8; //chroma intra pred mode

      mvp,
      mv_skip,
      mv: motionvec_t;        //mvs: predicted, skip, coded
      mvp1, mv1: motionvec_t; //partition mvp/mv for P16x8 mbPartIdx=1
      ref: int8;              //reference frame L0 index
      cbp: int8;              //cpb bitmask: 0..3 luma, 4 chroma DC only, 5 chroma AC
      fref: frame_p;          //reference frame selected for inter prediction

      //luma
      pfenc,
      pfdec,
      pfpred: PUInt8;
      pixels: PUInt8;        //original pixels
      pred:   PUInt8;        //intra predicted pixels
      mcomp:  PUInt8;        //motion-compensated (inter predicted) pixels
      pixels_dec: PUInt8;    //decoded pixels

      //chroma
      pfenc_c,
      pfdec_c,
      pfpred_c: array[0..1] of PUInt8;
      pixels_c,
      pred_c,
      mcomp_c,
      pixels_dec_c: array[0..1] of PUInt8;

      //motion estimation, analysis
      score_skip,
      score_skip_uv_ssd: integer;
      residual_bits: int16;
      bitcost: int16;                    //currently unused

      //coef arrays
      dct: array[0..24] of PInt16;      //0-15 - luma, 16-23 - chroma, 24 - luma DC
      chroma_dc: array[0..1, 0..3] of int16;
      block: array[0..26] of block_t;    //0-24 as in dct, 25/26 chroma_dc u/v

      //cache for speeding up the prediction process
      intra_pixel_cache: array[0..33] of byte;
      {   0,17 - top left pixel
         1..16 - pixels from top row
        18..33 - pixels from left column
      }

      //non-zero coef count of surrounding blocks for I4x4/I16x16/chroma ac blocks; write-combined in mb_init
      nz_coef_cnt: array[0..23] of byte;
      nz_coef_cnt_chroma_ac: array[0..1, 0..7] of byte;

      //transquant
      quant_ctx_qp, quant_ctx_qpc: TQuantCtx;

      //neighboring MBs, used for cavlc NZ counts, intra prediction, filtering strength
      mba, mbb: macroblock_p;

      //loopfilter: boundary filtering strength for vertically/horizontally adjacent blocks
      bS_vertical, bS_horizontal: TBSarray;
      bS_zero: boolean;                  //shortcut
  end;

  //frame
  frame_t = record
      //info
      num: integer;                   //frame number
      qp: int8;                       //fixed quant parameter
      num_ref_frames: int8;           //L0 reference picture count
      ftype: int8;                    //slice type
      idr: boolean;                   //IDR flag for I slices (unused)
      mbs: macroblock_p;              //frame macroblocks

      //img data
      mbw, mbh: integer;              //macroblock width, height
      stride, stride_c: integer;      //luma stride, chroma stride
      plane: array[0..2] of pbyte;    //image planes
      luma_mc: array[0..3] of pbyte;  //luma planes for hpel interpolated samples (none, h, v, h+v)
      luma_mc_qpel: array[0..7] of pbyte;  //plane pointers for qpel mc
      plane_dec: array[0..2] of pbyte;//decoded image planes
      frame_mem_offset,               //padding to image offset in bytes
      frame_mem_offset_cr: integer;
      blk_offset: array[0..15] of integer;        //4x4 block offsets

      refs: array[0..15] of frame_p;  //L0 reference list
      lowres: frame_p;                //low resolution frame for fast motion estimation

      //mb-adaptive quant data
      aq_table: pbyte;                //qp table
      qp_avg: single;                 //average quant

      //bitstream buffer
      bs_buf: pbyte;

      //stats, RC
      stats: TCodingStats;
      estimated_framebits: integer;
      qp_adj: integer;

      //rarely used data
      mem: array[0..5] of pbyte;      //allocated memory
      filter_hv_temp: psmallint;      //temp storage for fir filter
      w, h: integer;                  //width, height in 16-pixel granularity
      pw, ph: int16;                  //padded w&h
  end;

function is_intra(const m: integer): boolean; inline;
function is_inter(const m: integer): boolean; inline;

(*******************************************************************************
*******************************************************************************)
implementation

operator = (const a, b: motionvec_t): boolean; inline;
begin
  result := integer(a) = integer(b);
end;

operator / (const a: motionvec_t; const divisor: integer): motionvec_t;
begin
  result.x := a.x div divisor;
  result.y := a.y div divisor;
end;

operator * (const a: motionvec_t; const multiplier: integer): motionvec_t;
begin
  result.x := a.x * multiplier;
  result.y := a.y * multiplier;
end;

operator + (const a, b: motionvec_t): motionvec_t;
begin
  result.x := a.x + b.x;
  result.y := a.y + b.y;
end;

operator - (const a, b: motionvec_t): motionvec_t;
begin
  result.x := a.x - b.x;
  result.y := a.y - b.y;
end;

function XYToMVec(const x: integer; const y: integer): motionvec_t;
begin
  Result.x := x;
  Result.y := y;
end;

function is_intra(const m: integer): boolean; inline;
begin
  result := m in [MB_I_4x4, MB_I_16x16, MB_I_PCM];
end;

function is_inter(const m: integer): boolean; inline;
begin
  result := m in [MB_P_16x16, MB_P_SKIP, MB_P_16x8];
end;

{ TMotionVectorList }

function TMotionVectorList.GetItem(i: byte): motionvec_t;
begin
  Assert(i < Count);
  result := mvs[i];
end;

procedure TMotionVectorList.Add(const mv: motionvec_t);
begin
  Assert(Count <= High(mvs));
  mvs[Count] := mv;
  Count += 1;
end;

procedure TMotionVectorList.Clear;
begin
  Count := 0;
end;

end.
             
