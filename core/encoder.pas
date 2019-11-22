(*******************************************************************************
encoder.pas
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

unit encoder;
{$mode objfpc}

interface

uses
  sysutils, common, util, parameters, frame, h264stream, stats, pgm, loopfilter, loopfilter_threading,
  intra_pred, motion_comp, motion_est, ratecontrol, image, mb_encoder;

type
  { TFevh264Encoder }

  TFevh264Encoder = class
    public
      dump_decoded_frames: boolean;

      { Create encoder with desired parameters.
      Param instance is bound to encoder and shouldn't be modified until the encoder is freed
      }
      constructor Create(var param: TEncodingParameters);
      destructor Free;
      procedure EncodeFrame(const img: TPlanarImage; buffer: pbyte; out stream_size: longword);
      procedure GetLastFrameSSD(out ssd: array of int64);
      procedure GetLastFrame(out last_frame: frame_t);

    private
      h264s: TH264Stream;
      mb_enc: TMacroblockEncoder;
      fenc: frame_t;  //currently encoded frame
      stats: TStreamStats;
      frame_num: integer;

      width,
      height: integer;
      key_interval: integer;  //IDR interval
      last_keyframe_num: integer;
      num_ref_frames: integer;
      mb_width,
      mb_height,
      mb_count: integer;

      //encoder configuration
      _param: TEncodingParameters;
      stats_file: textfile;

      //classes
      frames: TFrameManager;
      rc: TRatecontrol;
      mc: TMotionCompensation;
      me: TMotionEstimator;
      deblocker: TDeblocker;

      procedure SetISlice;
      procedure SetPSlice;
      function TryEncodeFrame(const img: TPlanarImage): boolean;
      function SceneCut(const mbrow: integer): boolean;
      procedure WriteStats;
      procedure UpdateStats;
      procedure DumpFrame;
      procedure LoopfilterInit;
      procedure LoopfilterAdvanceRow;
      procedure LoopfilterAbort;
      procedure LoopfilterDone;
  end;


(*******************************************************************************
*******************************************************************************)
implementation


{ TFevh264Encoder }

constructor TFevh264Encoder.Create(var param: TEncodingParameters);
begin
  _param := param;

  //check&set params
  width   := param.FrameWidth;
  height  := param.FrameHeight;
  num_ref_frames := param.NumReferenceFrames;
  key_interval := param.KeyFrameInterval;

  frame_num := 0;
  last_keyframe_num := 0;
  mb_width  := width  div 16;
  mb_height := height div 16;
  if (width  and $f) > 0 then mb_width  += 1;
  if (height and $f) > 0 then mb_height += 1;
  mb_count := mb_width * mb_height;

  //stream settings
  h264s := TH264Stream.Create(width, height, mb_width, mb_height);
  h264s.QP := param.QParam;
  h264s.ChromaQPOffset := param.ChromaQParamOffset;
  h264s.KeyInterval := key_interval;
  h264s.NumRefFrames := num_ref_frames;
  if not param.LoopFilterEnabled then
      h264s.DisableLoopFilter;

  //allocate frames
  frames := TFrameManager.Create(num_ref_frames, mb_width, mb_height);

  //inter pred
  mc := TMotionCompensation.Create;
  me := TMotionEstimator.Create(width, height, mb_width, mb_height, mc, h264s);
  me.subme := param.SubpixelMELevel;

  //ratecontrol
  rc := TRatecontrol.Create;
  if param.ABRRateControlEnabled then
      rc.Set2pass(param.Bitrate, param.FrameCount, param.FrameRate, param.stats_1pass_filename)
  else
      rc.SetConstQP(param.QParam);

  //mb encoder
  case param.AnalysisLevel of
      0: mb_enc := TMBEncoderNoAnalyse.Create;
      1: mb_enc := TMBEncoderQuickAnalyse.Create;
      2: mb_enc := TMBEncoderQuickAnalyseSATD.Create;
  else
      mb_enc := TMBEncoderRDoptAnalyse.Create;
  end;
  mb_enc.num_ref_frames := num_ref_frames;
  mb_enc.chroma_coding := true;
  mb_enc.mc := mc;
  mb_enc.me := me;
  mb_enc.h264s := h264s;
  mb_enc.ChromaQPOffset := param.ChromaQParamOffset;
  mb_enc.chroma_coding := not param.IgnoreChroma;
  mb_enc.LoopFilter := param.LoopFilterEnabled;

  deblocker := TDeblocker.Create();

  //stats
  stats := TStreamStats.Create;
  h264s.SEIString := param.ToString;
  if param.WriteStatsFile then begin
      AssignFile(stats_file, param.stats_filename);
      Rewrite(stats_file);
      writeln(stats_file, h264s.SEIString);
  end;
end;


destructor TFevh264Encoder.Free;
begin
  WriteStats;
  if _param.WriteStatsFile then
      CloseFile(stats_file);
  rc.Free;
  frames.Free;
  me.Free;
  mc.Free;
  h264s.Free;
  mb_enc.Free;
  deblocker.Free;
  stats.Free;
end;


procedure TFevh264Encoder.EncodeFrame(const img: TPlanarImage; buffer: pbyte; out stream_size: longword);
begin
  frames.GetFree(fenc);
  frame_img2frame_copy(fenc, img);
  fenc.num := frame_num;

  //set frame params
  if (frame_num = 0) or (frame_num - last_keyframe_num >= key_interval) then
      SetISlice
  else
      SetPSlice;

  //encode frame (or reencode P as I)
  if TryEncodeFrame(img) = false then begin
      SetISlice;
      TryEncodeFrame(img);
  end;

  //convert bitstream to bytestream of NAL units
  h264s.GetSliceBitstream(buffer, stream_size);

  //prepare reference frame for ME
  LoopfilterDone;
  frame_paint_edges(fenc);
  if _param.SubpixelMELevel > 0 then
      frame_hpel_interpolate(fenc);

  //stats
  rc.Update(frame_num, stream_size * 8, fenc);
  fenc.stats.size_bytes := stream_size;
  if _param.WriteStatsFile then
      frame_write_stats(stats_file, fenc);
  UpdateStats;
  if dump_decoded_frames then DumpFrame;

  //advance
  frames.InsertRef(fenc);
  frame_num += 1;
  dsp.FpuReset;
end;

procedure TFevh264Encoder.SetISlice;
begin
  fenc.ftype := SLICE_I;
  last_keyframe_num := frame_num;
end;

procedure TFevh264Encoder.SetPSlice;
begin
  fenc.num_ref_frames := min(num_ref_frames, frame_num - last_keyframe_num);
  fenc.ftype := SLICE_P;
  frames.SetRefs(fenc, frame_num, fenc.num_ref_frames);
  me.NumReferences := fenc.num_ref_frames;
end;

function TFevh264Encoder.TryEncodeFrame(const img: TPlanarImage): boolean;
var
  x, y: integer;
begin
  result := true;

  //init slice bitstream
  if img.QParam <> QPARAM_AUTO then
      fenc.qp := img.QParam
  else
      fenc.qp := rc.GetQP(frame_num, fenc.ftype);
  h264s.InitSlice(fenc.ftype, fenc.qp, fenc.num_ref_frames, fenc.bs_buf);

  //frame encoding setup
  fenc.stats.Clear;
  mb_enc.SetFrame(fenc);
  LoopfilterInit;

  //encode rows
  for y := 0 to (mb_height - 1) do begin
      for x := 0 to (mb_width - 1) do
          mb_enc.Encode(x, y);

      if SceneCut(y) then begin
          LoopfilterAbort;
          h264s.AbortSlice;
          result := false;
          break;
      end;

      LoopfilterAdvanceRow;
  end;
end;


function TFevh264Encoder.SceneCut(const mbrow: integer): boolean;
begin
  result := false;
  if (fenc.ftype = SLICE_P) and (mbrow > mb_height div 2) then begin
      if (2 * fenc.stats.mb_i4_count > mb_count)
        or (4 * integer(fenc.stats.mb_i16_count) > 3 * mb_count)
        or (8 * integer(fenc.stats.mb_i4_count + fenc.stats.mb_i16_count) > 7 * mb_count)
      then
          result := true;
  end;
end;


procedure TFevh264Encoder.GetLastFrameSSD(out ssd: array of int64);
begin
  case Length(ssd) of
      0:;
      1..2:
          ssd[0] := fenc.stats.ssd[0];
      else begin
          ssd[0] := fenc.stats.ssd[0];
          ssd[1] := fenc.stats.ssd[1];
          ssd[2] := fenc.stats.ssd[2];
      end;
  end;
end;


procedure TFevh264Encoder.GetLastFrame(out last_frame: frame_t);
begin
  last_frame := fenc;
end;


//write final stream stats to file
procedure TFevh264Encoder.WriteStats;
begin
  if _param.WriteStatsFile then begin
      stats.WriteStreamInfo(stats_file);
      stats.WriteMBInfo(stats_file);
      stats.WritePredictionInfo(stats_file);
      stats.WriteReferenceInfo(stats_file, num_ref_frames);
  end;
  stats.WriteReferenceInfo(stdout, num_ref_frames);
end;


//update stream stats with current frame's stats
procedure TFevh264Encoder.UpdateStats;
begin
  if fenc.ftype = SLICE_I then
      stats.i_count += 1
  else
      stats.p_count += 1;
  stats.Add(fenc.stats);
end;


//save reconstructed luma & chroma planes to file
procedure TFevh264Encoder.DumpFrame;
var
  s: string;
begin
  s := format('fdec%6d', [frame_num]);
  pgm_save(s + '.pgm', fenc.mem[3], fenc.pw, fenc.ph);
  if mb_enc.chroma_coding then begin
      pgm_save(s + '-cr.pgm', fenc.mem[4], fenc.pw div 2, fenc.ph div 2);
      pgm_save(s + '-cb.pgm', fenc.mem[5], fenc.pw div 2, fenc.ph div 2);
  end;
end;


procedure TFevh264Encoder.LoopfilterInit;
begin
  if not _param.LoopFilterEnabled then
      exit;
  if _param.FilterThreadEnabled then
      deblocker.BeginFrame(fenc, not(_param.AdaptiveQuant));
end;

procedure TFevh264Encoder.LoopfilterAdvanceRow;
begin
  if not _param.LoopFilterEnabled then
      exit;
  if _param.FilterThreadEnabled then
      deblocker.MBRowFinished;
end;

procedure TFevh264Encoder.LoopfilterAbort;
begin
  if _param.FilterThreadEnabled then
      deblocker.FinishFrame(true);
end;

//finish frame filtering, if enabled. If it's disabled, SSD is already calculated at the last stage of macroblock encoding
procedure TFevh264Encoder.LoopfilterDone;
var
  mby: Integer;
  cqp: boolean;
begin
  if not _param.LoopFilterEnabled then
      exit;

  if _param.FilterThreadEnabled then begin
      deblocker.FinishFrame;
  end else begin
      cqp := not _param.AdaptiveQuant;
      for mby := 0 to fenc.mbh - 1 do begin
          DeblockMBRow(mby, fenc, cqp);
          //the bottom edge will be filtered in the next iteration, so SSD should be behind by a single row
          if mby > 0 then
              frame_decoded_macroblock_row_ssd(@fenc, mby - 1);
      end;
      frame_decoded_macroblock_row_ssd(@fenc, fenc.mbh - 1);
  end;
end;


(*******************************************************************************
*******************************************************************************)
var
  flags: TDsp_init_flags;

initialization
  //asm
  flags.mmx := true;
  flags.sse2 := true;
  frame_init(flags);
  intra_pred_init(flags);
  dsp := TDsp.Create(flags);
end.

