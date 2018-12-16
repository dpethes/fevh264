(*******************************************************************************
mb_encoder.pas
Copyright (c) 2011-2017 David Pethes

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
unit mb_encoder;

{$mode objfpc}{$H+}

interface

uses
  common, util, macroblock, frame, stats,
  intra_pred, inter_pred, motion_comp, motion_est, loopfilter, h264stream;

type

  { TMacroblockEncoder }

  TMacroblockEncoder = class
    private
      mb: macroblock_t;
      frame: frame_t;
      stats: TFrameStats;
      intrapred: TIntraPredictor;

      procedure InitMB(mbx, mby: integer);
      procedure FinalizeMB;
      procedure EncodeCurrentType;
      procedure Decode;
      procedure SetChromaQPOffset(const AValue: shortint);
      procedure Store;
      function TrySkip(const use_satd: boolean = true): boolean;
      function TryPostInterEncodeSkip(const score_inter: integer): boolean;
      procedure MakeSkip;
      function GetChromaMcSSD: integer;

    public
      mc: TMotionCompensation;
      me: TMotionEstimator;
      h264s: TH264Stream;
      chroma_coding: boolean;  //todo private
      num_ref_frames: integer;
      LoopFilter: boolean;
      property ChromaQPOffset: shortint write SetChromaQPOffset;

      constructor Create; virtual;
      destructor Free; virtual;
      procedure SetFrame(const f: frame_t); virtual;
      procedure Encode(mbx, mby: integer); virtual; abstract;
  end;

  { TMBEncoderNoAnalyse }

  TMBEncoderNoAnalyse = class(TMacroblockEncoder)
      constructor Create; override;
      procedure Encode(mbx, mby: integer); override;
  end;

  { TMBEncoderQuickAnalyse }

  TMBEncoderQuickAnalyse = class(TMacroblockEncoder)
    public
      procedure Encode(mbx, mby: integer); override;
  end;

  { TMBEncoderQuickAnalyseSATD }

  TMBEncoderQuickAnalyseSATD = class(TMBEncoderQuickAnalyse)
    private
      InterCost: IInterPredCostEvaluator;
    public
      constructor Create; override;
      procedure SetFrame(const f: frame_t); override;
      procedure Encode(mbx, mby: integer); override;
  end;

  { TMBEncoderRateAnalyse }

  TMBEncoderRateAnalyse = class(TMacroblockEncoder)
    private
      mb_cache: array[0..2] of macroblock_t; //todo init in constructor
      mb_type_bitcost: array[MB_I_4x4..MB_P_SKIP] of integer;
      procedure CacheStore;
      procedure CacheLoad;
      procedure EncodeInter;
      procedure EncodeIntra;
      function MBCost: integer;
    public
      constructor Create; override;
      destructor Free; override;
      procedure Encode(mbx, mby: integer); override;
  end;


implementation

const
  MIN_I_4x4_BITCOST = 27;

{ TMacroblockEncoder }

procedure TMacroblockEncoder.InitMB(mbx, mby: integer);
begin
  mb.x := mbx;
  mb.y := mby;
  if mbx = 0 then
      mb_init_row_ptrs(mb, frame, mby);

  //load pixels
  dsp.pixel_load_16x16(mb.pixels,      mb.pfenc,      frame.stride  );
  dsp.pixel_load_8x8  (mb.pixels_c[0], mb.pfenc_c[0], frame.stride_c);
  dsp.pixel_load_8x8  (mb.pixels_c[1], mb.pfenc_c[1], frame.stride_c);

  mb_init(mb, frame);
  mb.residual_bits := 0;
  mb.fref := frame.refs[0];
  mb.ref  := 0;
end;

//some nz_coef_cnt-s are set in Decode, therefore it must come before CalculateBStrength
procedure TMacroblockEncoder.FinalizeMB;
begin
  h264s.WriteMB(mb);
  Decode;
  if LoopFilter then begin
      CalculateBStrength(@mb);
  end;
  Store;
  if not LoopFilter then begin
      stats.ssd[0] += dsp.ssd_16x16(mb.pixels_dec,      mb.pfenc,      frame.stride  );
      stats.ssd[1] += dsp.ssd_8x8  (mb.pixels_dec_c[0], mb.pfenc_c[0], frame.stride_c);
      stats.ssd[2] += dsp.ssd_8x8  (mb.pixels_dec_c[1], mb.pfenc_c[1], frame.stride_c);
  end;

  mb.pfenc += 16;
  mb.pfdec += 16;
  mb.pfenc_c[0] += 8;
  mb.pfenc_c[1] += 8;
  mb.pfdec_c[0] += 8;
  mb.pfdec_c[1] += 8;
end;

procedure TMacroblockEncoder.EncodeCurrentType;
begin
  case mb.mbtype of
      //MB_P_SKIP: no coding

      MB_I_4x4: begin
          encode_mb_intra_i4(mb, frame, intrapred);
          if chroma_coding then
              encode_mb_chroma(mb, intrapred, true);
      end;

      MB_I_16x16: begin
          intrapred.Predict_16x16(mb.i16_pred_mode, mb.x, mb.y);
          encode_mb_intra_i16(mb);
          if chroma_coding then
              encode_mb_chroma(mb, intrapred, true);
      end;

      MB_P_16x16: begin
          encode_mb_inter(mb);
          if chroma_coding then begin
              mc.CompensateChroma(mb.fref, mb.mv, mb.x, mb.y, mb.mcomp_c[0], mb.mcomp_c[1]);
              encode_mb_chroma(mb, intrapred, false);
          end;
      end;

      MB_I_PCM: begin
          //necessary for proper cavlc initialization for neighboring blocks
          FillByte(mb.nz_coef_cnt, 16, 16);
          FillByte(mb.nz_coef_cnt_chroma_ac[0], 4, 16);
          FillByte(mb.nz_coef_cnt_chroma_ac[1], 4, 16);
      end;
  end;
  if is_intra(mb.mbtype) then begin
      mb.mv := ZERO_MV;
      mb.ref := -1;
  end;
end;

procedure TMacroblockEncoder.Decode;
begin
  case mb.mbtype of
      MB_I_PCM: decode_mb_pcm(mb);
      //MB_I_4x4: decoded during encode
      MB_I_16x16:
          decode_mb_intra_i16(mb, intrapred);
      MB_P_16x16:
          decode_mb_inter(mb);
      MB_P_SKIP:
          decode_mb_inter_pskip(mb);
  end;
  if chroma_coding and (mb.mbtype <> MB_I_PCM) then
      decode_mb_chroma(mb, is_intra(mb.mbtype));
end;

procedure TMacroblockEncoder.SetChromaQPOffset(const AValue: shortint);
begin
  mb.chroma_qp_offset := AValue;
end;

//store MB to frame's MB array, move decoded pixels to frame
procedure TMacroblockEncoder.Store;
var
  i: integer;
begin
  i := mb.y * frame.mbw + mb.x;
  move(mb, frame.mbs[i], sizeof(macroblock_t));

  if mb.mbtype <> MB_I_4x4 then
      dsp.pixel_save_16x16(mb.pixels_dec, mb.pfdec, frame.stride);
  dsp.pixel_save_8x8 (mb.pixels_dec_c[0], mb.pfdec_c[0], frame.stride_c);
  dsp.pixel_save_8x8 (mb.pixels_dec_c[1], mb.pfdec_c[1], frame.stride_c);

  //stats
  case mb.mbtype of
      MB_I_4x4: begin
          stats.mb_i4_count += 1;
          for i := 0 to 15 do
              stats.pred[mb.i4_pred_mode[i]] += 1;
          stats.pred_8x8_chroma[mb.chroma_pred_mode] += 1;
          stats.itex_bits += mb.residual_bits;
      end;
      MB_I_16x16: begin
          stats.mb_i16_count += 1;
          stats.pred16[mb.i16_pred_mode] += 1;
          stats.pred_8x8_chroma[mb.chroma_pred_mode] += 1;
          stats.itex_bits += mb.residual_bits;
      end;
      MB_P_16x16: begin
          stats.mb_p_count += 1;
          stats.ref[mb.ref] += 1;
          stats.ptex_bits += mb.residual_bits;
      end;
      MB_P_SKIP: begin
          stats.mb_skip_count += 1;
          stats.ref[mb.ref] += 1;
      end;
  end;
end;


const
  MIN_XY = -FRAME_EDGE_W * 4;

{ PSkip test, based on SSD treshold. Also stores SATD luma & SSD chroma score
  true = PSkip is acceptable
}
function TMacroblockEncoder.TrySkip(const use_satd: boolean = true): boolean;
const
  SKIP_SSD_TRESH = 256;
  SKIP_SSD_CHROMA_TRESH = 96;
var
  mv: motionvec_t;
  score, score_c: integer;
begin
  result := false;
  mb.score_skip := MaxInt;
  if h264s.NoPSkipAllowed then exit;

  if (mb.y < frame.mbh - 1) or (mb.x < frame.mbw - 1) then begin
      mv := mb.mv_skip;

      //can't handle out-of-frame mvp, don't skip
      if mv.x + mb.x * 64 >= frame.w * 4 - 34 then exit;
      if mv.y + mb.y * 64 >= frame.h * 4 - 34 then exit;
      if mv.x + mb.x * 64 < MIN_XY then exit;
      if mv.y + mb.y * 64 < MIN_XY then exit;

      mb.mv := mv;
      mc.Compensate(mb.fref, mb.mv, mb.x, mb.y, mb.mcomp);
      score := dsp.ssd_16x16(mb.pixels, mb.mcomp, 16);
      if use_satd then
          mb.score_skip := dsp.satd_16x16(mb.pixels, mb.mcomp, 16)
      else
          mb.score_skip := dsp.sad_16x16 (mb.pixels, mb.mcomp, 16);
      score_c := 0;
      if chroma_coding then begin
          mc.CompensateChroma(mb.fref, mb.mv, mb.x, mb.y, mb.mcomp_c[0], mb.mcomp_c[1]);
          score_c += GetChromaMcSSD;
      end;
      mb.score_skip_uv := score_c;

      if (score < SKIP_SSD_TRESH) and (score_c < SKIP_SSD_CHROMA_TRESH) then
          result := true;
  end;
end;


//test if PSkip is suitable: luma SATD & chroma SSD can't be (much) worse than compensated P16x16
//todo: better tune skip bias
function TMacroblockEncoder.TryPostInterEncodeSkip(const score_inter: integer): boolean;
var
  skip_bias: integer;
begin
  result := false;
  skip_bias := mb.qp * 3;
  if score_inter >= mb.score_skip - skip_bias then begin
      if chroma_coding then begin
        skip_bias := mb.qp;
        if GetChromaMcSSD >= mb.score_skip_uv - skip_bias then
            result := true;
      end else
          result := true;
  end;
end;


//test if mb can be changed to skip
procedure TMacroblockEncoder.MakeSkip;
var
  mv: motionvec_t;
begin
  if h264s.NoPSkipAllowed then exit;
  mv := mb.mv_skip;

  //can't handle out-of-frame mvp, don't skip
  if mv.x + mb.x * 64 >= frame.w * 4 - 34 then exit;
  if mv.y + mb.y * 64 >= frame.h * 4 - 34 then exit;
  if mv.x + mb.x * 64 < MIN_XY then exit;
  if mv.y + mb.y * 64 < MIN_XY then exit;

  if (mb.cbp = 0) and ( (mb.y < frame.mbh - 1) or (mb.x < frame.mbw - 1) ) then begin
      //restore skip ref/mv
      if (mb.ref <> 0) or (mb.mbtype <> MB_P_16x16) then begin
          mb.fref := frame.refs[0];
          mb.ref := 0;
          InterPredLoadMvs(mb, frame, num_ref_frames);
      end;
      mb.mbtype := MB_P_SKIP;
      mb.mv     := mb.mv_skip;
      mc.Compensate(mb.fref, mb.mv, mb.x, mb.y, mb.mcomp);
      if chroma_coding then
          mc.CompensateChroma(mb.fref, mb.mv, mb.x, mb.y, mb.mcomp_c[0], mb.mcomp_c[1]);
  end;
end;


function TMacroblockEncoder.GetChromaMcSSD: integer;
begin
  result := dsp.ssd_8x8(mb.pixels_c[0], mb.mcomp_c[0], 16)
          + dsp.ssd_8x8(mb.pixels_c[1], mb.mcomp_c[1], 16);
end;

constructor TMacroblockEncoder.Create;
begin
  mb_alloc(mb);
  mb.chroma_qp_offset := 0;
  intrapred := TIntraPredictor.Create;
  with intrapred do begin
      pixels     := mb.pixels;
      prediction := mb.pred;
      pixels_c[0] := mb.pixels_c[0];
      pixels_c[1] := mb.pixels_c[1];
      prediction_c[0] := mb.pred_c[0];
      prediction_c[1] := mb.pred_c[1];
      pixel_cache := @mb.intra_pixel_cache;
  end;
end;

destructor TMacroblockEncoder.Free;
begin
  mb_free(mb);
  intrapred.Free;
end;

procedure TMacroblockEncoder.SetFrame(const f: frame_t);
begin
  frame := f;
  intrapred.frame_stride := frame.stride;
  intrapred.stride_c := frame.stride_c;
  intrapred.mb_width := frame.mbw;
  stats := f.stats;
end;


{ TMBEncoderRateAnalyse }

procedure TMBEncoderRateAnalyse.CacheStore;
begin
  with mb_cache[mb.mbtype] do begin
      mv   := mb.mv;
      ref  := mb.ref;
      fref := mb.fref;
      cbp  := mb.cbp;
      chroma_dc      := mb.chroma_dc;
      nz_coef_cnt    := mb.nz_coef_cnt;
      nz_coef_cnt_dc := mb.nz_coef_cnt_dc;
      nz_coef_cnt_chroma_ac := mb.nz_coef_cnt_chroma_ac;
      block          := mb.block;
  end;
  move(mb.dct[0]^, mb_cache[mb.mbtype].dct[0]^, 2 * 16 * 25);
end;

procedure TMBEncoderRateAnalyse.CacheLoad;
begin
  with mb_cache[mb.mbtype] do begin
      mb.mv                    := mv;
      mb.ref                   := ref;
      mb.fref                  := fref;
      mb.cbp                   := cbp;
      mb.chroma_dc             := chroma_dc;
      mb.nz_coef_cnt           := nz_coef_cnt;
      mb.nz_coef_cnt_dc        := nz_coef_cnt_dc;
      mb.nz_coef_cnt_chroma_ac := nz_coef_cnt_chroma_ac;
      mb.block                 := block;
  end;
  move(mb_cache[mb.mbtype].dct[0]^, mb.dct[0]^, 2 * 16 * 25);
end;

function TMBEncoderRateAnalyse.MBCost: integer;
begin
  result := h264s.GetBitCost(mb);
  mb_type_bitcost[mb.mbtype] := result;
end;


constructor TMBEncoderRateAnalyse.Create;
var
  i: integer;
begin
  inherited Create;
  intrapred.UseSATDCompare;
  for i := 0 to 2 do
      mb_cache[i].dct[0] := fev_malloc(2 * 16 * 25);
end;

destructor TMBEncoderRateAnalyse.Free;
var
  i: integer;
begin
  inherited Free;
  for i := 0 to 2 do
      fev_free(mb_cache[i].dct[0]);
end;


procedure TMBEncoderRateAnalyse.EncodeInter;
var
  score_i, score_p: integer;
  bits_i16, bits_intra, bits_inter: integer;
begin
  mb.mbtype := MB_P_16x16;
  InterPredLoadMvs(mb, frame, num_ref_frames);

  //early PSkip
  if TrySkip then begin
      mb.mbtype := MB_P_SKIP;
      mb_type_bitcost[mb.mbtype] := 0;
      exit;
  end;

  //encode as inter
  me.Estimate(mb, frame);
  score_p := dsp.satd_16x16(mb.pixels, mb.mcomp, 16);
  EncodeCurrentType;

  //if there were no coeffs left after quant, try if PSkip is suitable; otherwise just exit with P16x16
  if (mb.cbp = 0) and TryPostInterEncodeSkip(score_p) then begin
      MakeSkip;
      //makeskip may fail in turning the MB to skip, so technically not correct; but it's used only in analysis
      mb_type_bitcost[mb.mbtype] := 0;
      exit;
  end;

  bits_inter := MBCost;

  //early termination if surrounding MBs are inter and have similar bitcost
  if (mb.mba <> nil) and (mb.mbb <> nil) and is_inter(mb.mba^.mbtype) and is_inter(mb.mbb^.mbtype)
      and (bits_inter < (mb.mba^.bitcost + mb.mbb^.bitcost) div 3 * 2) then
          exit;

  //encode as intra if prediction score isn't much worse
  intrapred.Analyse_16x16(mb.x, mb.y, mb.i16_pred_mode, score_i);
  if score_i < score_p * 2 then begin
      CacheStore;
      //I16x16
      mb.mbtype := MB_I_16x16;
      EncodeCurrentType;
      bits_i16 := MBCost;
      //try I4x4 if I16x16 wasn't much worse
      if (bits_i16 < bits_inter * 2) and (min(bits_inter, bits_i16) > MIN_I_4x4_BITCOST) then begin
          CacheStore;
          mb.mbtype := MB_I_4x4;
          EncodeCurrentType;
          bits_intra := MBCost;
          //pick better
          if bits_i16 < bits_intra then begin
              mb.mbtype := MB_I_16x16;
              CacheLoad;
              bits_intra := bits_i16;
          end;
      end else
          bits_intra := bits_i16;

      //inter / intra?
      if bits_inter < bits_intra then begin
          mb.mbtype := MB_P_16x16;
          CacheLoad;
      end;
  end;
end;

procedure TMBEncoderRateAnalyse.EncodeIntra;
var
  bits_i16, bits_i4: integer;
  score_i: integer;
begin
  intrapred.Analyse_16x16(mb.x, mb.y, mb.i16_pred_mode, score_i);
  mb.mbtype := MB_I_16x16;
  EncodeCurrentType;
  CacheStore;
  bits_i16 := MBCost;
  if bits_i16 <= MIN_I_4x4_BITCOST then
      exit;

  mb.mbtype := MB_I_4x4;
  EncodeCurrentType;
  bits_i4 := MBCost;
  if bits_i16 < bits_i4 then begin
      mb.mbtype := MB_I_16x16;
      CacheLoad;
  end;
end;

procedure TMBEncoderRateAnalyse.Encode(mbx, mby: integer);
begin
  InitMB(mbx, mby);

  if frame.ftype = SLICE_P then
      EncodeInter
  else
      EncodeIntra;

  mb.bitcost := mb_type_bitcost[mb.mbtype];
  FinalizeMB;
end;


{ TMBEncoderQuickAnalyse }

procedure TMBEncoderQuickAnalyse.Encode(mbx, mby: integer);
const
  I16_SAD_QPBONUS = 10;
var
  score_i, score_p: integer;
begin
  InitMB(mbx, mby);

  //encode
  if frame.ftype = SLICE_P then begin
      mb.mbtype := MB_P_16x16;
      InterPredLoadMvs(mb, frame, num_ref_frames);

      //skip
      if TrySkip then begin
          mb.mbtype := MB_P_SKIP;
          FinalizeMB;
          exit;
      end;

      //inter score
      me.Estimate(mb, frame);
      score_p := dsp.sad_16x16(mb.pixels, mb.mcomp, 16);

      //intra score
      intrapred.Analyse_16x16(mb.x, mb.y, mb.i16_pred_mode, score_i);
      if score_i < score_p then begin
          if score_i < mb.qp * I16_SAD_QPBONUS then
              mb.mbtype := MB_I_16x16
          else
              mb.mbtype := MB_I_4x4;
          mb.ref := 0;
      end;

      //encode mb
      EncodeCurrentType;

      //if there were no coeffs left, try skip
      if is_inter(mb.mbtype) and (mb.cbp = 0) and TryPostInterEncodeSkip(score_p) then begin
          MakeSkip;
      end;

  end else begin
      mb.mbtype := MB_I_4x4;
      EncodeCurrentType;
  end;

  FinalizeMB;
end;


{ TMBEncoderQuickAnalyseSATD }

constructor TMBEncoderQuickAnalyseSATD.Create;
begin
  inherited Create;
  intrapred.UseSATDCompare;
end;

procedure TMBEncoderQuickAnalyseSATD.SetFrame(const f: frame_t);
begin
  inherited SetFrame(f);
  InterCost := h264s.GetInterPredCostEvaluator;
end;

procedure TMBEncoderQuickAnalyseSATD.Encode(mbx, mby: integer);
const
  I16_SATD_QPBONUS = 50;
  INTRA_MODE_PENALTY = 10;

var
  score_i, score_p: integer;

begin
  InitMB(mbx, mby);

  //encode
  if frame.ftype = SLICE_P then begin
      mb.mbtype := MB_P_16x16;
      InterPredLoadMvs(mb, frame, num_ref_frames);

      //skip
      if TrySkip(true) then begin
          mb.mbtype := MB_P_SKIP;
          FinalizeMB;
          exit;
      end;

      //inter score
      me.Estimate(mb, frame);
      score_p := dsp.satd_16x16(mb.pixels, mb.mcomp, 16);
      score_p += InterCost.BitCost(mb.mv - mb.mvp);

      //intra score
      intrapred.Analyse_16x16(mb.x, mb.y, mb.i16_pred_mode, score_i);
      if score_i + INTRA_MODE_PENALTY < score_p then begin
          if score_i < mb.qp * I16_SATD_QPBONUS then
              mb.mbtype := MB_I_16x16
          else
              mb.mbtype := MB_I_4x4;
          mb.ref := 0;
      end;

      //encode mb
      EncodeCurrentType;

      //if there were no coeffs left, try skip
      if is_inter(mb.mbtype) and (mb.cbp = 0) and TryPostInterEncodeSkip(score_p) then begin
          MakeSkip;
      end;

  end else begin
      intrapred.Analyse_16x16(mb.x, mb.y, mb.i16_pred_mode, score_i);
      if score_i < mb.qp * I16_SATD_QPBONUS then
          mb.mbtype := MB_I_16x16
      else
          mb.mbtype := MB_I_4x4;
      EncodeCurrentType;
  end;

  FinalizeMB;
end;


{ TMBEncoderNoAnalyse }

constructor TMBEncoderNoAnalyse.Create;
begin
  inherited Create;
end;

procedure TMBEncoderNoAnalyse.Encode(mbx, mby: integer);
begin
  InitMB(mbx, mby);

  if frame.ftype = SLICE_P then begin
      mb.mbtype := MB_P_16x16;
      InterPredLoadMvs(mb, frame, num_ref_frames);
      //skip
      if TrySkip(false) then begin
          mb.mbtype := MB_P_SKIP;
      end else begin
          me.Estimate(mb, frame);
          EncodeCurrentType;
      end;
  end else begin
      mb.mbtype := MB_I_4x4;
      EncodeCurrentType;
  end;

  FinalizeMB;
end;

end.

