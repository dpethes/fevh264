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
      mb_can_use_pskip: boolean;
      cache_motion: record
        mv, mvp: motionvec_t;
      end;

      procedure InitMB(mbx, mby: integer);
      procedure InitForInter;
      procedure FinalizeMB;
      procedure AdvanceFramePointers;
      procedure CacheMvStore;
      procedure CacheMvLoad;
      procedure EncodeCurrentType;
      procedure Decode;
      procedure SetChromaQPOffset(const AValue: shortint);
      function TrySkip(const use_satd: boolean = true): boolean;
      function TryPostInterEncodeSkip(const score_inter: integer): boolean;
      procedure MakeSkip;
      function GetChromaMcSSD: integer;

    public
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
      InterCost: TInterPredCost;
    public
      constructor Create; override;
      procedure SetFrame(const f: frame_t); override;
      procedure Encode(mbx, mby: integer); override;
  end;

  { TMBEncoderRDoptAnalyse }

  TMBEncoderRDoptAnalyse = class(TMacroblockEncoder)
    private
      mb_cache: array[MB_I_4x4..MB_P_16x16] of macroblock_t; //todo init in constructor
      mb_type_bitcost: array[MB_I_4x4..MB_P_16x8] of integer;
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

  { TMBEncoderLowresRun }
  TMBEncoderLowresRun = class(TMacroblockEncoder)
    public
      constructor Create; override;
      procedure SetFrame(const f: frame_t); override;
      procedure Encode(mbx, mby: integer); override;
  end;


implementation

const
  MIN_I_4x4_BITCOST = 27;
  MB_I_PCM_BITCOST = 8*384 + 9;

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

procedure TMacroblockEncoder.EncodeCurrentType;
begin
  Assert(mb.qp = mb.quant_ctx_qp.qp);
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
              MotionCompensation.CompensateChroma(mb.fref, mb.mv, mb.x, mb.y, mb.mcomp_c[0], mb.mcomp_c[1]);
              encode_mb_chroma(mb, intrapred, false);
          end;
      end;

      MB_P_16x8: begin
          encode_mb_inter(mb);
          if chroma_coding then begin
              MotionCompensation.CompensateChroma_8x4(mb.fref, mb.mv,  mb.x, mb.y, mb.mcomp_c[0], mb.mcomp_c[1], 0);
              MotionCompensation.CompensateChroma_8x4(mb.fref, mb.mv1, mb.x, mb.y, mb.mcomp_c[0], mb.mcomp_c[1], 1);
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
      MB_P_16x16, MB_P_16x8:
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

{ Write mb to bitstream, decode and write pixels to frame and store MB to frame's MB array.
  Update stats and calculate SSD if the loopfilter isn't enabled (otherwise get it later,
  after all relevant pixels are decoded)
}
procedure TMacroblockEncoder.FinalizeMB;
var
  i: Integer;
begin
  h264s.WriteMB(mb);
  Decode;

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
      MB_I_PCM: begin
          stats.mb_ipcm_count += 1;
          stats.itex_bits += mb.residual_bits;
      end;
      MB_P_16x16, MB_P_16x8: begin
          stats.mb_p_count += 1;
          stats.ref[mb.ref] += 1;
          stats.ptex_bits += mb.residual_bits;
      end;
      MB_P_SKIP: begin
          stats.mb_skip_count += 1;
          stats.ref[mb.ref] += 1;
      end;
  end;

  if not LoopFilter then begin
      stats.ssd[1] += dsp.ssd_8x8  (mb.pixels_dec_c[0], mb.pixels_c[0], 16);
      stats.ssd[2] += dsp.ssd_8x8  (mb.pixels_dec_c[1], mb.pixels_c[1], 16);
      stats.ssd[0] += dsp.ssd_16x16(mb.pixels_dec,      mb.pixels,      16);
  end else begin
      //some nz_coef_cnt-s are set in Decode(), so it must be called first
      CalculateBStrength(@mb);
  end;

  i := mb.y * frame.mbw + mb.x;
  move(mb, frame.mbs[i], sizeof(macroblock_t));
  AdvanceFramePointers;
end;

procedure TMacroblockEncoder.AdvanceFramePointers;
begin
  mb.pfenc += 16;
  mb.pfdec += 16;
  mb.pfenc_c[0] += 8;
  mb.pfenc_c[1] += 8;
  mb.pfdec_c[0] += 8;
  mb.pfdec_c[1] += 8;
end;

procedure TMacroblockEncoder.CacheMvStore;
begin
  cache_motion.mv := mb.mv;
  cache_motion.mvp := mb.mvp;
end;

procedure TMacroblockEncoder.CacheMvLoad;
begin
  mb.mv := cache_motion.mv;
  mb.mvp := cache_motion.mvp;
end;

const
  MIN_XY = -FRAME_EDGE_W * 4;

procedure TMacroblockEncoder.InitForInter;
var
  mv: motionvec_t;
begin
  InterPredLoadMvs(mb, frame, num_ref_frames);
  mb_can_use_pskip := false;
  if h264s.NoPSkipAllowed then exit;
  if (mb.y < frame.mbh - 1) or (mb.x < frame.mbw - 1) then begin
      mv := mb.mv_skip;

      //can't handle out-of-frame mvp, don't skip
      if mv.x + mb.x * 64 >= frame.w * 4 - 34 then exit;
      if mv.y + mb.y * 64 >= frame.h * 4 - 34 then exit;
      if mv.x + mb.x * 64 < MIN_XY then exit;
      if mv.y + mb.y * 64 < MIN_XY then exit;

      mb_can_use_pskip := true;
  end;
end;

{ PSkip test, based on SSD treshold. Also stores SATD luma & SSD chroma score
  true = PSkip is acceptable
}
function TMacroblockEncoder.TrySkip(const use_satd: boolean = true): boolean;
const
  SKIP_SSD_TRESH = 256;
  SKIP_SSD_CHROMA_TRESH = 96;
var
  score, score_c: integer;
begin
  result := false;
  mb.score_skip := MaxInt;
  if not mb_can_use_pskip then exit;

  mb.mv := mb.mv_skip;
  MotionCompensation.Compensate(mb.fref, mb.mv, mb.x, mb.y, mb.mcomp);
  score := dsp.ssd_16x16(mb.pixels, mb.mcomp, 16);
  if use_satd then
      mb.score_skip := dsp.satd_16x16(mb.pixels, mb.mcomp, 16)
  else
      mb.score_skip := dsp.sad_16x16 (mb.pixels, mb.mcomp, 16);
  score_c := 0;
  if chroma_coding then begin
      MotionCompensation.CompensateChroma(mb.fref, mb.mv, mb.x, mb.y, mb.mcomp_c[0], mb.mcomp_c[1]);
      score_c := GetChromaMcSSD;
  end;
  mb.score_skip_uv_ssd := score_c;

  if (score < SKIP_SSD_TRESH) and (score_c < SKIP_SSD_CHROMA_TRESH) then
      result := true;
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
        if GetChromaMcSSD >= mb.score_skip_uv_ssd - skip_bias then
            result := true;
      end else
          result := true;
  end;
end;


//test if mb can be changed to skip
procedure TMacroblockEncoder.MakeSkip;
begin
  if not mb_can_use_pskip then exit;

  //restore skip ref/mv
  if (mb.ref <> 0) or not is_inter(mb.mbtype) then begin
      mb.fref := frame.refs[0];
      mb.ref := 0;
      InterPredLoadMvs(mb, frame, num_ref_frames);
  end;
  mb.mbtype := MB_P_SKIP;
  mb.mv     := mb.mv_skip;
  MotionCompensation.Compensate(mb.fref, mb.mv, mb.x, mb.y, mb.mcomp);
  if chroma_coding then
      MotionCompensation.CompensateChroma(mb.fref, mb.mv, mb.x, mb.y, mb.mcomp_c[0], mb.mcomp_c[1]);
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
  intrapred.SetMB(@mb);
end;

destructor TMacroblockEncoder.Free;
begin
  mb_free(mb);
  intrapred.Free;
end;

procedure TMacroblockEncoder.SetFrame(const f: frame_t);
begin
  frame := f;
  intrapred.SetFrame(@frame);
  stats := f.stats;
  mb_init_frame_invariant(mb, frame);
end;


{ TMBEncoderRDoptAnalyse }

procedure TMBEncoderRDoptAnalyse.CacheStore;
begin
  Assert(mb.mbtype <= MB_P_16x16);
  with mb_cache[mb.mbtype] do begin
      mv   := mb.mv;
      ref  := mb.ref;
      fref := mb.fref;
      cbp  := mb.cbp;
      chroma_dc      := mb.chroma_dc;
      nz_coef_cnt    := mb.nz_coef_cnt;
      nz_coef_cnt_chroma_ac := mb.nz_coef_cnt_chroma_ac;
      block          := mb.block;
  end;
  move(mb.dct[0]^, mb_cache[mb.mbtype].dct[0]^, MB_DCT_ARRAY_SIZE);
end;

procedure TMBEncoderRDoptAnalyse.CacheLoad;
begin
  with mb_cache[mb.mbtype] do begin
      mb.mv                    := mv;
      mb.ref                   := ref;
      mb.fref                  := fref;
      mb.cbp                   := cbp;
      mb.chroma_dc             := chroma_dc;
      mb.nz_coef_cnt           := nz_coef_cnt;
      mb.nz_coef_cnt_chroma_ac := nz_coef_cnt_chroma_ac;
      mb.block                 := block;
  end;
  move(mb_cache[mb.mbtype].dct[0]^, mb.dct[0]^, MB_DCT_ARRAY_SIZE);
end;

function TMBEncoderRDoptAnalyse.MBCost: integer;
begin
  result := h264s.GetBitCost(mb);
  mb_type_bitcost[mb.mbtype] := result;
end;


constructor TMBEncoderRDoptAnalyse.Create;
var
  i: integer;
begin
  inherited Create;
  intrapred.UseSATDCompare;
  for i := 0 to 2 do
      mb_cache[i].dct[0] := fev_malloc(2 * 16 * 25);
  mb_type_bitcost[MB_P_SKIP] := 0;
end;

destructor TMBEncoderRDoptAnalyse.Free;
var
  i: integer;
begin
  inherited Free;
  for i := 0 to 2 do
      fev_free(mb_cache[i].dct[0]);
end;


procedure TMBEncoderRDoptAnalyse.EncodeInter;
const
  LAMBDA_MBTYPE: array[0..51] of byte = (  //todo tune lambdas
     4,  4,  4,  4,  4,  4,  4,  4,  4,  4,
     4,  4,  4,  4,  4,  4,  4,  4,  4,  4,
    16, 16, 16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16, 16, 16,
    24, 24, 24, 24, 24, 24, 24, 24, 24, 24,
    32, 32
  );
  //todo merge both tables; lambda+4 gains results closer to the old lambda at qp18-24+
  LAMBDA_MBTYPE_PSKIP: array[0..51] of byte = (
     1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 2, 2, 2, 2,  // 0..19
     3, 3, 3, 4, 4, 4, 5, 6, 6, 7,  8, 9,10,11,13,14,16,18,20,23,  //20..39
    25,29,32,36,40,45,51,57,64,72, 81,91                           //40..51
  ); //lx = pow(2, qp/6.0 - 2)
var
  score_i4, score_intra, score_p: integer;
  bits_i4, bits_intra, bits_inter: integer;
  mode_lambda: integer;
  score_p_chroma: integer;
  can_switch_to_skip: boolean;

  score_psub, bits_inter_sub: integer;
  sub_16x16: boolean;

begin
  mb.mbtype := MB_P_16x16;
  InitForInter;

  //early PSkip
  if TrySkip then begin
      mb.mbtype := MB_P_SKIP;
      me.Skipped(mb);
      exit;
  end;

  //encode as inter
  me.Estimate(mb, frame);
  score_p := dsp.satd_16x16(mb.pixels, mb.mcomp, 16);
  EncodeCurrentType;
  bits_inter := MBCost;

  mode_lambda := LAMBDA_MBTYPE_PSKIP[mb.qp];

  //encode as PSkip if inter doesn't improve things much; MB_P_16x16 costs at least 4 bits (5 if multiref)
  if (mb.cbp = 0) and mb_can_use_pskip then begin
      can_switch_to_skip := mb.score_skip <= score_p + mode_lambda * bits_inter;

      //compare chroma as well, in case the pskip chroma was bad
      if can_switch_to_skip and chroma_coding then begin
          score_p_chroma := GetChromaMcSSD;
          can_switch_to_skip := mb.score_skip_uv_ssd <= score_p_chroma + (mode_lambda * bits_inter div 4);
      end;

      if can_switch_to_skip then begin
          MakeSkip;
          me.Skipped(mb);
          exit;
      end;
  end;

  //encode as intra if prediction score isn't much worse
  mb.i16_pred_mode := intrapred.Analyse_16x16();
  score_intra := intrapred.LastScore;
  if score_intra < score_p * 2 then begin
      //I16x16
      CacheStore;
      mb.mbtype := MB_I_16x16;
      EncodeCurrentType;
      bits_intra := MBCost;
      //try I4x4 if I16x16 wasn't much worse
      if (bits_intra < bits_inter * 2) and (min(bits_inter, bits_intra) > MIN_I_4x4_BITCOST) then begin
          CacheStore;
          mb.mbtype := MB_I_4x4;
          EncodeCurrentType;
          bits_i4  := MBCost;
          score_i4 := intrapred.LastScore;

          //pick better
          if bits_intra < bits_i4 then begin
              mb.mbtype := MB_I_16x16;
              CacheLoad;
          end else begin
              bits_intra  := bits_i4;
              score_intra := score_i4;
          end;
      end;
      //inter / intra?
      mode_lambda := LAMBDA_MBTYPE[mb.qp];
      if mode_lambda * bits_inter + score_p < mode_lambda * bits_intra + score_intra then begin
          mb.mbtype := MB_P_16x16;
          CacheLoad;
      end else if bits_intra > MB_I_PCM_BITCOST then begin
          mb.mbtype := MB_I_PCM;
          EncodeCurrentType;
      end;
  end;

  sub_16x16 := true;
  if (mb.mbtype = MB_P_16x16) and sub_16x16 then begin
      CacheMvStore;
      mb.mbtype := MB_P_16x8;
      me.Estimate_16x8(mb);
      InterPredLoadMvs(mb, frame, num_ref_frames);  //mvp can differ and mvp1 can change based on surrounding MBs and top mv

      score_psub := dsp.satd_16x16(mb.pixels, mb.mcomp, 16);
      EncodeCurrentType;
      bits_inter_sub := MBCost;

      mode_lambda := LAMBDA_MBTYPE_PSKIP[mb.qp];
      if (me.Subme > 4) then  //bias somewhat against MB_P_16x8, as it does not have qpel rdo refinement
          mode_lambda *= 4;
      if (mb.mv = mb.mv1) or (bits_inter * mode_lambda + score_p < bits_inter_sub * mode_lambda + score_psub) then begin
          mb.mbtype := MB_P_16x16;
          CacheMvLoad;
          MotionCompensation.Compensate(mb.fref, mb.mv, mb.x, mb.y, mb.mcomp);
          EncodeCurrentType;  //TODO cache?
      end;
  end;

  //apply rdo refinement only if there is residual to work with to save some time at negligible quality cost
  if (mb.mbtype = MB_P_16x16) and (mb.cbp > 0) and (me.Subme > 4) then begin
      me.Refine(mb);
      EncodeCurrentType;
  end;
end;

procedure TMBEncoderRDoptAnalyse.EncodeIntra;
var
  bits_i16, bits_i4: integer;
begin
  mb.i16_pred_mode := intrapred.Analyse_16x16();
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
  end else if bits_i4 > MB_I_PCM_BITCOST then begin
      mb.mbtype := MB_I_PCM;
      EncodeCurrentType;
  end;
end;

procedure TMBEncoderRDoptAnalyse.Encode(mbx, mby: integer);
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
      InitForInter;

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
      mb.i16_pred_mode := intrapred.Analyse_16x16();
      score_i := intrapred.LastScore;
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
  InterCost := h264s.InterPredCost;
end;

procedure TMBEncoderQuickAnalyseSATD.Encode(mbx, mby: integer);
const
  I16_SATD_QPBONUS = 50;
  INTRA_MODE_PENALTY = 10;

var
  score_i, score_p, score_psub: integer;
  sub_16x16: boolean;

begin
  InitMB(mbx, mby);

  //encode
  if frame.ftype = SLICE_P then begin
      mb.mbtype := MB_P_16x16;
      InitForInter;

      //skip
      if TrySkip(true) then begin
          mb.mbtype := MB_P_SKIP;
          FinalizeMB;
          exit;
      end;

      //inter score
      me.Estimate(mb, frame);
      score_p := dsp.satd_16x16(mb.pixels, mb.mcomp, 16);
      score_p += InterCost.Bits(mb.mv);

      //intra score
      mb.i16_pred_mode := intrapred.Analyse_16x16();
      score_i := intrapred.LastScore;
      if score_i + INTRA_MODE_PENALTY < score_p then begin
          if score_i < mb.qp * I16_SATD_QPBONUS then
              mb.mbtype := MB_I_16x16
          else
              mb.mbtype := MB_I_4x4;
          mb.ref := 0;
      end;

      //if there were no coeffs left, try skip
      if is_inter(mb.mbtype) and (mb.cbp = 0) and TryPostInterEncodeSkip(score_p) then begin
          MakeSkip;
      end;

      sub_16x16 := true;
      if (mb.mbtype = MB_P_16x16) and sub_16x16 then begin
          CacheMvStore;
          mb.mbtype := MB_P_16x8;
          me.Estimate_16x8(mb);
          InterPredLoadMvs(mb, frame, num_ref_frames);  //mvp can differ and mvp1 can change based on surrounding MBs and top mv

          score_psub := dsp.satd_16x16(mb.pixels, mb.mcomp, 16);
          score_psub += 2 * (InterCost.Bits(mb.mv - mb.mvp) + InterCost.Bits(mb.mv1 - mb.mvp1));

          if (mb.mv = mb.mv1) or (score_p < score_psub) then begin
              mb.mbtype := MB_P_16x16;
              CacheMvLoad;
              MotionCompensation.Compensate(mb.fref, mb.mv, mb.x, mb.y, mb.mcomp);
          end;
      end;

      //encode mb
      EncodeCurrentType;

  end else begin
      mb.i16_pred_mode := intrapred.Analyse_16x16();
      score_i := intrapred.LastScore;
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
      InitForInter;
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

{ TMBEncoderLowresRun }

constructor TMBEncoderLowresRun.Create;
begin
  inherited Create;
end;

procedure TMBEncoderLowresRun.SetFrame(const f: frame_t);
var
  i: integer;
begin
  frame := f.lowres^;
  frame.qp := f.qp;
  for i := 0 to f.num_ref_frames - 1 do
      frame.refs[i] := f.refs[i]^.lowres;
end;

procedure TMBEncoderLowresRun.Encode(mbx, mby: integer);
var
  i: integer;
begin
  InitMB(mbx, mby);
  me.Estimate(mb, frame);

  i := mb.y * frame.mbw + mb.x;
  frame.mbs[i].mv := mb.mv;
  AdvanceFramePointers;
end;

end.

