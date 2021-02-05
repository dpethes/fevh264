(*******************************************************************************
macroblock.pas
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

unit macroblock;
{$mode objfpc}

interface

uses
  stdint, common, util, pixel, intra_pred, transquant, vlc, h264tables;

procedure mb_alloc(var mb: macroblock_t);
procedure mb_free(var mb: macroblock_t);
procedure mb_init_row_ptrs(var mb: macroblock_t; const frame: frame_t; const y: integer);
procedure mb_init_frame_invariant(var mb: macroblock_t; var frame: frame_t);
procedure mb_init(var mb: macroblock_t; var frame: frame_t; const adaptive_quant: boolean = false);

procedure encode_mb_intra_i4(var mb: macroblock_t; var frame: frame_t; const intrapred: TIntraPredictor);

procedure encode_mb_intra_i16(var mb: macroblock_t);
procedure decode_mb_intra_i16(var mb: macroblock_t; const intrapred: TIntraPredictor);

procedure encode_mb_inter(var mb: macroblock_t);
procedure decode_mb_inter(var mb: macroblock_t);

procedure decode_mb_inter_pskip(var mb: macroblock_t);
procedure decode_mb_pcm(var mb: macroblock_t);

procedure encode_mb_chroma(var mb: macroblock_t; const intrapred: TIntraPredictor; const intra: boolean);
procedure decode_mb_chroma(var mb: macroblock_t; const intra: boolean);

(*******************************************************************************
*******************************************************************************)
implementation

procedure mb_alloc(var mb: macroblock_t);
var
  i: integer;
begin
  //memory layout: pixels | pred | mcomp | pixels_dec | pixels uv | pred | mcomp uv | pixels_dec uv
  mb.pixels := fev_malloc(256 * 4 {luma} + 64 * 2 * 4 {chroma});
  mb.pred   := mb.pixels + 256;
  mb.mcomp  := mb.pred + 256;
  mb.pixels_dec := mb.mcomp + 256;

  mb.pixels_c[0] := mb.pixels + 256 * 4;
  mb.pixels_c[1] := mb.pixels_c[0] + 8;
  mb.pred_c[0]   := mb.pixels_c[0] + 128;
  mb.pred_c[1]   := mb.pred_c[0] + 8;
  mb.mcomp_c[0]  := mb.pred_c[0] + 128;
  mb.mcomp_c[1]  := mb.mcomp_c[0] + 8;
  mb.pixels_dec_c[0] := mb.mcomp_c[0] + 128;
  mb.pixels_dec_c[1] := mb.pixels_dec_c[0] + 8;

  mb.dct[0] := fev_malloc(MB_DCT_ARRAY_SIZE);
  for i := 1 to 24 do
      mb.dct[i] := mb.dct[i - 1] + 16;
end;

procedure mb_free(var mb: macroblock_t);
begin
  fev_free(mb.pixels);
  fev_free(mb.dct[0]);
end;

procedure mb_init_row_ptrs(var mb: macroblock_t; const frame: frame_t; const y: integer);
begin
  mb.pfenc := frame.plane[0] + y * 16 * frame.stride;
  mb.pfenc_c[0] := frame.plane[1] + y * 8 * frame.stride_c;
  mb.pfenc_c[1] := frame.plane[2] + y * 8 * frame.stride_c;

  mb.pfdec := frame.plane_dec[0] + y * 16 * frame.stride;
  mb.pfdec_c[0] := frame.plane_dec[1] + y * 8 * frame.stride_c;
  mb.pfdec_c[1] := frame.plane_dec[2] + y * 8 * frame.stride_c;
end;

procedure fill_all_nonzero_counts(var mb: macroblock_t; value: int64); inline;
begin
  pint64(@mb.nz_coef_cnt[0])^  := value;  //equal to FillByte(mb.nz_coef_cnt, 24+8+8, value);
  pint64(@mb.nz_coef_cnt[8])^  := value;
  pint64(@mb.nz_coef_cnt[16])^ := value;
  pint64(@mb.nz_coef_cnt_chroma_ac[0, 0])^ := value;
  pint64(@mb.nz_coef_cnt_chroma_ac[1, 0])^ := value;
end;


(*******************************************************************************
initialize mb structure:
-intra prediction mode, block non-zero counts for cavlc
-qp related parts
-intra pred pixel cache

 There's some write-combine action going on - it needs to be re-checked if
 macroblock_t layout is modified
*)

procedure mb_init_qp_struct(var mb: macroblock_t);
begin
  if mb.qp < 30 then
      mb.qpc := mb.qp
  else
      mb.qpc := tab_qp_chroma[mb.qp];
  mb.qpc += mb.chroma_qp_offset;
  transqt_init_for_qp(mb.quant_ctx_qp,  mb.qp);
  transqt_init_for_qp(mb.quant_ctx_qpc, mb.qpc);
end;

procedure mb_init_frame_invariant(var mb: macroblock_t; var frame: frame_t);
begin
  mb.qp := frame.qp;
  mb_init_qp_struct(mb);
end;

procedure mb_init(var mb: macroblock_t; var frame: frame_t; const adaptive_quant: boolean = false);
var
  mbb, mba: macroblock_p;
  src, dst: pbyte;
  i: integer;
begin
  pint64(@mb.i4_pred_mode[0])^  := -1;  //equal to FillByte(mb.i4_pred_mode, 24, INTRA_PRED_NA);
  pint64(@mb.i4_pred_mode[8])^  := -1;
  pint64(@mb.i4_pred_mode[16])^ := -1;
  mb.chroma_pred_mode := INTRA_PRED_CHROMA_DC;

  mb.mba := nil;
  mb.mbb := nil;
  fill_all_nonzero_counts(mb, -1);  //NZ_COEF_CNT_NA

  //top mb
  if mb.y > 0 then begin
     mbb := @frame.mbs[ (mb.y - 1) * frame.mbw + mb.x];
     mb.mbb := mbb;

     if mbb^.mbtype = MB_I_4x4 then begin
         mb.i4_pred_mode[16] := mbb^.i4_pred_mode[10];
         mb.i4_pred_mode[17] := mbb^.i4_pred_mode[11];
         mb.i4_pred_mode[18] := mbb^.i4_pred_mode[14];
         mb.i4_pred_mode[19] := mbb^.i4_pred_mode[15];
     end else begin
         mb.i4_pred_mode[16] := INTRA_PRED_DC;
         mb.i4_pred_mode[17] := INTRA_PRED_DC;
         mb.i4_pred_mode[18] := INTRA_PRED_DC;
         mb.i4_pred_mode[19] := INTRA_PRED_DC;
     end;

     mb.nz_coef_cnt[16] := mbb^.nz_coef_cnt[10];
     mb.nz_coef_cnt[17] := mbb^.nz_coef_cnt[11];
     mb.nz_coef_cnt[18] := mbb^.nz_coef_cnt[14];
     mb.nz_coef_cnt[19] := mbb^.nz_coef_cnt[15];

     for i := 0 to 1 do begin
         mb.nz_coef_cnt_chroma_ac[i, 4] := mbb^.nz_coef_cnt_chroma_ac[i, 2];
         mb.nz_coef_cnt_chroma_ac[i, 5] := mbb^.nz_coef_cnt_chroma_ac[i, 3];
     end;
  end;

  //left mb
  if mb.x > 0 then begin
     mba := @frame.mbs[ mb.y * frame.mbw + mb.x - 1];
     mb.mba := mba;

     if mba^.mbtype = MB_I_4x4 then begin
         mb.i4_pred_mode[20] := mba^.i4_pred_mode[ 5];
         mb.i4_pred_mode[21] := mba^.i4_pred_mode[ 7];
         mb.i4_pred_mode[22] := mba^.i4_pred_mode[13];
         mb.i4_pred_mode[23] := mba^.i4_pred_mode[15];
     end else begin
         mb.i4_pred_mode[20] := INTRA_PRED_DC;
         mb.i4_pred_mode[21] := INTRA_PRED_DC;
         mb.i4_pred_mode[22] := INTRA_PRED_DC;
         mb.i4_pred_mode[23] := INTRA_PRED_DC;
     end;

     mb.nz_coef_cnt[20] := mba^.nz_coef_cnt[ 5];
     mb.nz_coef_cnt[21] := mba^.nz_coef_cnt[ 7];
     mb.nz_coef_cnt[22] := mba^.nz_coef_cnt[13];
     mb.nz_coef_cnt[23] := mba^.nz_coef_cnt[15];

     for i := 0 to 1 do begin
         mb.nz_coef_cnt_chroma_ac[i, 6] := mba^.nz_coef_cnt_chroma_ac[i, 1];
         mb.nz_coef_cnt_chroma_ac[i, 7] := mba^.nz_coef_cnt_chroma_ac[i, 3];
     end;
  end;

  //qp
  mb.qp := frame.qp;
  if adaptive_quant then begin
      mb.qp := frame.aq_table[mb.y * frame.mbw + mb.x];
      mb_init_qp_struct(mb);
  end;

  { fill I16x16 prediction pixel cache
      0,17 - top left pixel
     1..16 - pixels from top
    18..33 - pixels from left
  }
  dst := @mb.intra_pixel_cache;
  src := mb.pfdec - frame.stride - 1;  //top - use 16 pixels from decoded frame
  pint64(dst)^   := pint64(src)^;
  pint64(dst+8)^ := pint64(src+8)^;
  dst[16] := src[16];
  dst[17] := dst[0];                   //top left
  src := mb.pixels_dec + 15;           //left - use rightmost pixel row from previously decoded mb
  for i := 0 to 15 do dst[i+18] := src[i * 16];

  //debug: clear some data areas that don't need clearing under normal circumstances
  {
  FillByte(mb.block, SizeOf(mb.block), 0);
  }
end;


(*******************************************************************************
intra coding
*)
const SAD_DECIMATE_TRESH: array[0..51] of word = (
    3,   3,   3,   3,   3,   3,   4,   4,   5,   5,
    6,   7,   8,   9,  10,  11,  13,  14,  16,  18,
   20,  22,  26,  28,  32,  36,  40,  44,  52,  56,
   64,  72,  80,  88, 104, 112, 128, 144, 160, 176,
  208, 224, 256, 288, 320, 352, 416, 448, 512, 576,
  640, 704
);

procedure block_use_zero(var b: block_t); inline;
begin
  b.nlevel := 0;
  b.t1 := 0;
end;


procedure encode_mb_intra_i4
  (var mb: macroblock_t; var frame: frame_t; const intrapred: TIntraPredictor);
var
  i: integer;
  block: int16_p;
  overall_coefs: array[0..3] of integer;
  sad, sad_tresh: integer;
  block_offset: integer;
  block_coefs: integer;

begin
  for i := 0 to 3 do overall_coefs[i] := 0;
  sad_tresh := SAD_DECIMATE_TRESH[mb.qp];

  intrapred.LastScore := 0;
  for i := 0 to 15 do begin
      block := mb.dct[i];
      block_offset := BLOCK_OFFSET_4[i];

      mb.i4_pred_mode[i] := intrapred.Analyse_4x4(mb.pfdec + frame.blk_offset[i], i);
      sad := dsp.sad_4x4(mb.pixels + block_offset, mb.pred + block_offset, 16);
      if sad >= sad_tresh then begin
          dsp.pixel_sub_4x4(mb.pixels + block_offset, mb.pred + block_offset, block);
          transqt(block, mb.quant_ctx_qp, true);
          cavlc_analyse_block(mb.block[i], block, 16);

          block_coefs := mb.block[i].nlevel;
          mb.nz_coef_cnt[i] := block_coefs;
          overall_coefs[i shr 2] += block_coefs;
      end else begin
          block_use_zero(mb.block[i]);
          mb.nz_coef_cnt[i] := 0;
          block_coefs := 0;
      end;

      //decode block
      if block_coefs > 0 then begin
          itransqt(block, mb.quant_ctx_qp);
          dsp.pixel_add_4x4 (mb.pixels_dec + block_offset, mb.pred + block_offset, block);
      end else begin
          pixel_load_4x4(mb.pixels_dec + block_offset, mb.pred + block_offset, 16);
      end;

      pixel_save_4x4(mb.pixels_dec + block_offset, mb.pfdec  + frame.blk_offset[i], frame.stride);
  end;

  mb.cbp := 0;
  for i := 0 to 3 do
      if overall_coefs[i] > 0 then mb.cbp := mb.cbp or (1 shl i);
end;


procedure encode_mb_intra_i16(var mb: macroblock_t);
var
  i: integer;
  block: int16_p;
  overall_coefs: integer;

begin
  overall_coefs := 0;

  for i := 0 to 15 do begin
      block := mb.dct[i];

      dsp.pixel_sub_4x4(mb.pixels + BLOCK_OFFSET_4[i], mb.pred + BLOCK_OFFSET_4[i], block);
      transqt(block, mb.quant_ctx_qp, true, 1);

      mb.dct[24][ block_dc_order[i] ] := block[0];
      block[0] := 0;

      cavlc_analyse_block(mb.block[i], block, 15);
      mb.nz_coef_cnt[i] := mb.block[i].nlevel;
      overall_coefs += mb.nz_coef_cnt[i];
  end;

  //dc transform
  transqt_dc_4x4(mb.dct[24], mb.qp);
  cavlc_analyse_block(mb.block[24], mb.dct[24], 16);

  //overall_coefs: only 0 or 15
  if overall_coefs = 0 then
      mb.cbp := 0
  else
      mb.cbp := %1111;
end;


procedure decode_mb_intra_i16(var mb: macroblock_t; const intrapred: TIntraPredictor);
var
  i: integer;
  block: int16_p;

begin
  intrapred.Predict_16x16(mb.i16_pred_mode, mb.x, mb.y);

  itransqt_dc_4x4(mb.dct[24], mb.qp);

  for i := 0 to 15 do begin
      block := mb.dct[i];
      block[0] := mb.dct[24][ block_dc_order[i] ];

      if mb.nz_coef_cnt[i] > 0 then
          itransqt(block, mb.quant_ctx_qp, 1)
      else
          itrans_dc(block);

      dsp.pixel_add_4x4 (mb.pixels_dec + BLOCK_OFFSET_4[i], mb.pred + BLOCK_OFFSET_4[i], block);
  end;
end;



(*******************************************************************************
inter coding
*)
procedure encode_mb_inter(var mb: macroblock_t);
var
  i: integer;
  block: int16_p;
  overall_coefs: array[0..3] of integer;
  sad, sad_tresh: integer;
  block_offset: integer;

begin
  for i := 0 to 3 do overall_coefs[i] := 0;
  sad_tresh := SAD_DECIMATE_TRESH[mb.qp];

  for i := 0 to 15 do begin
      block := mb.dct[i];
      block_offset := BLOCK_OFFSET_4[i];

      sad := dsp.sad_4x4(mb.pixels + block_offset, mb.mcomp + block_offset, 16);
      if sad >= sad_tresh then begin
          dsp.pixel_sub_4x4(mb.pixels + block_offset, mb.mcomp + block_offset, block);
          transqt(block, mb.quant_ctx_qp, false);
          cavlc_analyse_block(mb.block[i], block, 16);
      end else
          block_use_zero(mb.block[i]);

      mb.nz_coef_cnt[i] := mb.block[i].nlevel;
      overall_coefs[i shr 2] += mb.nz_coef_cnt[i];
  end;

  mb.cbp := 0;
  for i := 0 to 3 do
      if overall_coefs[i] > 0 then mb.cbp := mb.cbp or (1 shl i);
end;


procedure decode_mb_inter(var mb: macroblock_t);
var
  i: integer;
  block: int16_p;
begin
  move(mb.mcomp^, mb.pixels_dec^, 256);  //prefill, so empty blocks are a no-op
  for i := 0 to 15 do begin
      block := mb.dct[i];

      if mb.nz_coef_cnt[i] > 0 then begin
          itransqt(block, mb.quant_ctx_qp);
          dsp.pixel_add_4x4 (mb.pixels_dec + BLOCK_OFFSET_4[i], mb.mcomp + BLOCK_OFFSET_4[i], block);
      end;
  end;
end;


procedure decode_mb_inter_pskip(var mb: macroblock_t);
begin
  move(mb.mcomp^, mb.pixels_dec^, 256);
  fill_all_nonzero_counts(mb, 0);
  mb.cbp := 0;
end;



(*******************************************************************************
chroma coding
*)
procedure encode_mb_chroma
  (var mb: macroblock_t; const intrapred: TIntraPredictor; const intra: boolean);
var
  i, j, n: integer;
  block: int16_p;
  pred: pbyte;
  sad, sad_tresh: integer;
  overall_ac_coefs, block_ac_coefs: integer;

begin
  overall_ac_coefs := 0;
  sad_tresh := SAD_DECIMATE_TRESH[mb.qpc];

  if intra then
      mb.chroma_pred_mode := intrapred.Analyse_8x8_chroma(mb.pfdec_c[0], mb.pfdec_c[1]);

  for j := 0 to 1 do begin
      if intra then
          pred := mb.pred_c[j]
      else
          pred := mb.mcomp_c[j];

      for i := 0 to 3 do begin
          n := 16 + i + j * 4;
          block := mb.dct[n];

          sad := dsp.sad_4x4(mb.pixels_c[j] + block_offset_chroma[i], pred + block_offset_chroma[i], 16);
          if sad >= sad_tresh then begin
              dsp.pixel_sub_4x4(mb.pixels_c[j] + block_offset_chroma[i], pred + block_offset_chroma[i], block);
              transqt(block, mb.quant_ctx_qpc, false, 1);
              mb.chroma_dc[j, i] := block[0];
              block[0] := 0;
              cavlc_analyse_block(mb.block[n], block, 15);

              block_ac_coefs := mb.block[n].nlevel;
              overall_ac_coefs += block_ac_coefs;
              mb.nz_coef_cnt_chroma_ac[j, i] := block_ac_coefs;
          end else begin
              block_use_zero(mb.block[n]);
              mb.chroma_dc[j, i] := 0;
              mb.nz_coef_cnt_chroma_ac[j, i] := 0
          end;
      end;
  end;

  //dc transform
  for j := 0 to 1 do begin
      transqt_dc_2x2(mb.chroma_dc[j], mb.qpc);
      cavlc_analyse_block_2x2(mb.block[25 + j], @mb.chroma_dc[j]);
  end;

  //cbp
  if overall_ac_coefs > 0 then
      mb.cbp := mb.cbp or (1 shl 5)
  else
      if (mb.block[25].nlevel + mb.block[26].nlevel > 0) then
          mb.cbp := mb.cbp or (1 shl 4);
end;



procedure decode_mb_chroma(var mb: macroblock_t; const intra: boolean);
var
  i, j: integer;
  block: int16_p;
  pred: pbyte;
begin
  if intra then
      pred := mb.pred_c[0]
  else
      pred := mb.mcomp_c[0];

  if mb.cbp shr 4 = 0 then begin
      //shortcut for no chroma residual case
      move(pred^, mb.pixels_dec_c[0]^, 128);

  end else begin

      for j := 0 to 1 do
          itransqt_dc_2x2(mb.chroma_dc[j], mb.qpc);

      for j := 0 to 1 do begin
          for i := 0 to 3 do begin
              block := mb.dct[16 + i + j * 4];
              block[0] := mb.chroma_dc[j, i];

              if mb.nz_coef_cnt_chroma_ac[j, i] > 0 then
                  itransqt(block, mb.quant_ctx_qpc, 1)
              else
                  itrans_dc(block);

              dsp.pixel_add_4x4 (mb.pixels_dec_c[j] + block_offset_chroma[i],
                                 pred + block_offset_chroma[i], block);
          end;
          pred += 8;  //second chroma plane block offset
      end;

  end;
end;


//I_PCM
procedure decode_mb_pcm(var mb: macroblock_t);
begin
  move(mb.pixels^, mb.pixels_dec^, 256);
  move(mb.pixels_c[0]^, mb.pixels_dec_c[0]^, 128);
  mb.cbp := 0;
end;


end.
