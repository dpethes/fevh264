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

  mb.dct[0] := fev_malloc(2 * 16 * 25);
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


{ fill I16x16 prediction pixel cache
    0,17 - top left pixel
   1..16 - pixels from top
  18..33 - pixels from left
}
procedure fill_intra_pred_cache(var mb: macroblock_t; var frame: frame_t);
var
  i: integer;
  src, dst: pbyte;
begin
  dst := @mb.intra_pixel_cache;
  //top - use pixels from decoded frame
  src := mb.pfdec - frame.stride - 1;
  move(src^, dst^, 17);
  //top left
  dst[17] := dst[0];
  //left - use rightmost pixel row from previously decoded mb
  src := mb.pixels_dec + 15;
  for i := 0 to 15 do dst[i+18] := src[i * 16];
end;


(*******************************************************************************
initialize mb structure:
-intra prediction
-non-zero count
-qp
-mvd, skip mv
*)
procedure mb_init(var mb: macroblock_t; var frame: frame_t; const adaptive_quant: boolean = false);
var
  mbb, mba: macroblock_p;
  i: integer;
begin
  FillByte(mb.i4_pred_mode, 24, INTRA_PRED_NA);
  mb.chroma_pred_mode := INTRA_PRED_CHROMA_DC;

  FillByte(mb.nz_coef_cnt, 24, NZ_COEF_CNT_NA);
  for i := 0 to 7 do mb.nz_coef_cnt_chroma_ac[0, i] := NZ_COEF_CNT_NA;
  for i := 0 to 7 do mb.nz_coef_cnt_chroma_ac[1, i] := NZ_COEF_CNT_NA;

  mb.mba := nil;
  mb.mbb := nil;

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
  if adaptive_quant then
      mb.qp := frame.aq_table[mb.y * frame.mbw + mb.x];
  if mb.qp < 30 then
      mb.qpc := mb.qp
  else
      mb.qpc := tab_qp_chroma[mb.qp];
  mb.qpc += mb.chroma_qp_offset;

  transqt_init_for_qp(mb.quant_ctx_qp,  mb.qp);
  transqt_init_for_qp(mb.quant_ctx_qpc, mb.qpc);

  //intra cache
  fill_intra_pred_cache(mb, frame);

  //debug: clear some data areas that don't need clearing under normal circumstances
  {
  FillByte(mb.block, SizeOf(mb.block), 0);
  }
end;


(*******************************************************************************
intra coding
*)
const SAD_DECIMATE_TRESH: array[0..54] of word = (
    3,   3,   3,   3,   3,   3,   4,   4,   5,   5,
    6,   7,   8,   9,  10,  11,  13,  14,  16,  18,
   20,  22,  26,  28,  32,  36,  40,  44,  52,  56,
   64,  72,  80,  88, 104, 112, 128, 144, 160, 176,
  208, 224, 256, 288, 320, 352, 416, 448, 512, 576,
  640, 704, 800, 900, 1000  //chroma uses qp+3
);

procedure block_use_zero(var b: block_t);
begin
  b.nlevel := 0;
  b.t1 := 0;
end;


procedure encode_mb_intra_i4
  (var mb: macroblock_t; var frame: frame_t; const intrapred: TIntraPredictor);
var
  i: integer;
  block: int16_p;
  cbp: array[0..3] of byte;
  sad, sad_tresh: integer;

begin
  for i := 0 to 3 do cbp[i] := 0;
  sad_tresh := SAD_DECIMATE_TRESH[mb.qp];

  intrapred.LastScore := 0;
  for i := 0 to 15 do begin
      block := mb.dct[i];

      mb.i4_pred_mode[i] := intrapred.Analyse_4x4(mb.pfdec + frame.blk_offset[i], i);
      sad := dsp.sad_4x4(mb.pixels + block_offset4[i], mb.pred + block_offset4[i], 16);
      if sad >= sad_tresh then begin
          dsp.pixel_sub_4x4(mb.pixels + block_offset4[i], mb.pred + block_offset4[i], block);
          transqt(block, mb.quant_ctx_qp, true);
          cavlc_analyse_block(mb.block[i], block, 16);
      end else
          block_use_zero(mb.block[i]);

      mb.nz_coef_cnt[i] := mb.block[i].nlevel;
      cbp[i shr 2] += mb.nz_coef_cnt[i];

      //decode block
      if mb.nz_coef_cnt[i] > 0 then begin
          itransqt(block, mb.quant_ctx_qp);
          dsp.pixel_add_4x4 (mb.pixels_dec + block_offset4[i], mb.pred + block_offset4[i], block);
      end else
          pixel_load_4x4(mb.pixels_dec + block_offset4[i], mb.pred + block_offset4[i], 16);

      pixel_save_4x4(mb.pixels_dec + block_offset4[i],
                     mb.pfdec  + frame.blk_offset[i], frame.stride);
  end;

  mb.cbp := 0;
  for i := 0 to 3 do
      if cbp[i] > 0 then mb.cbp := mb.cbp or (1 shl i);
end;


procedure encode_mb_intra_i16(var mb: macroblock_t);
var
  i: integer;
  block: int16_p;
  cbp: byte;

begin
  cbp := 0;

  for i := 0 to 15 do begin
      block := mb.dct[i];

      dsp.pixel_sub_4x4(mb.pixels + block_offset4[i], mb.pred + block_offset4[i], block);
      transqt(block, mb.quant_ctx_qp, true, 1);

      mb.dct[24][ block_dc_order[i] ] := block[0];
      block[0] := 0;

      cavlc_analyse_block(mb.block[i], block, 15);
      mb.nz_coef_cnt[i] := mb.block[i].nlevel;
      cbp += mb.nz_coef_cnt[i];
  end;

  //dc transform
  transqt_dc_4x4(mb.dct[24], mb.qp);
  cavlc_analyse_block(mb.block[24], mb.dct[24], 16);

  //cbp: only 0 or 15
  if cbp = 0 then
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

      dsp.pixel_add_4x4 (mb.pixels_dec + block_offset4[i], mb.pred + block_offset4[i], block);
  end;
end;



(*******************************************************************************
inter coding
*)
procedure encode_mb_inter(var mb: macroblock_t);
var
  i: integer;
  block: int16_p;
  cbp: array[0..3] of byte;
  sad, sad_tresh: integer;

begin
  for i := 0 to 3 do cbp[i] := 0;
  sad_tresh := SAD_DECIMATE_TRESH[mb.qp];

  for i := 0 to 15 do begin
      block := mb.dct[i];

      sad := dsp.sad_4x4(mb.pixels + block_offset4[i], mb.mcomp + block_offset4[i], 16);
      if sad >= sad_tresh then begin
          dsp.pixel_sub_4x4(mb.pixels + block_offset4[i], mb.mcomp + block_offset4[i], block);
          transqt(block, mb.quant_ctx_qp, false);
          cavlc_analyse_block(mb.block[i], block, 16);
      end else
          block_use_zero(mb.block[i]);

      mb.nz_coef_cnt[i] := mb.block[i].nlevel;
      cbp[i shr 2] += mb.nz_coef_cnt[i];
  end;

  mb.cbp := 0;
  for i := 0 to 3 do
      if cbp[i] > 0 then mb.cbp := mb.cbp or (1 shl i);
end;


procedure decode_mb_inter(var mb: macroblock_t);
var
  i: integer;
  block: int16_p;
begin
  for i := 0 to 15 do begin
      block := mb.dct[i];

      if mb.nz_coef_cnt[i] > 0 then begin
          itransqt(block, mb.quant_ctx_qp);
          dsp.pixel_add_4x4 (mb.pixels_dec + block_offset4[i], mb.mcomp + block_offset4[i], block);
      end else
          pixel_save_4x4(mb.mcomp + block_offset4[i], mb.pixels_dec + block_offset4[i], 16);
  end;
end;


procedure decode_mb_inter_pskip(var mb: macroblock_t);
begin
  move(mb.mcomp^, mb.pixels_dec^, 256);
  FillByte(mb.nz_coef_cnt, 16, 0);
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
  cbp_ac: byte;
  sad, sad_tresh: integer;

begin
  cbp_ac := 0;
  for i := 0 to 3 do begin
     mb.chroma_dc[0, i] := 0;
     mb.chroma_dc[1, i] := 0;
  end;
  sad_tresh := SAD_DECIMATE_TRESH[mb.qpc+3];

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
          end else begin
              block_use_zero(mb.block[n]);
              mb.chroma_dc[j, i] := 0;
          end;

          mb.nz_coef_cnt_chroma_ac[j, i] := mb.block[n].nlevel;
          if mb.nz_coef_cnt_chroma_ac[j, i] > 0 then
              cbp_ac += 1;
      end;
  end;

  //dc transform
  for j := 0 to 1 do begin
      transqt_dc_2x2(mb.chroma_dc[j], mb.qpc);
      cavlc_analyse_block_2x2(mb.block[25 + j], @mb.chroma_dc[j]);
  end;

  //cbp
  if cbp_ac > 0 then
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
  if mb.cbp shr 4 = 0 then begin
      //shortcut for no chroma residual case
      if intra then
          move(mb.pred_c[0]^,  mb.pixels_dec_c[0]^, 128)
      else begin
          move(mb.mcomp_c[0]^, mb.pixels_dec_c[0]^, 128);

          if (mb.mbtype = MB_P_SKIP) then
              FillByte(mb.nz_coef_cnt_chroma_ac, 16, 0);
      end;

  end else begin

      for j := 0 to 1 do
          itransqt_dc_2x2(mb.chroma_dc[j], mb.qpc);

      for j := 0 to 1 do begin
          if intra then
              pred := mb.pred_c[j]
          else
              pred := mb.mcomp_c[j];

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
