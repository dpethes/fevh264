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
{define DEBUG_Y4M_OUTPUT}

interface

uses
  sysutils, common, util, parameters, frame, h264stream, stats, pgm, loopfilter, loopfilter_threading,
  intra_pred, motion_est, ratecontrol, image, mb_encoder;

type
{$ifdef DEBUG_Y4M_OUTPUT}
  y4m_file = record
      hnd: file;
      file_header_size,
      frame_header_size: word;
      width,
      height: word;
      frame_size: longword;
      frame_count,
      current_frame: longword;
      frame_rate: double;
  end;
{$endif}

  { TFevh264Encoder }

  TFevh264Encoder = class
    public
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
      mb_enc_lowres: TMBEncoderLowresRun;
      fenc: frame_t;  //currently encoded frame
      stats: TCodingStats;
      frame_num: integer;

      width,
      height: integer;
      key_interval: integer;  //IDR interval
      last_keyframe_num: integer;
      num_ref_frames: integer;
      mb_width,
      mb_height,
      mb_count: integer;
      filter_ab_offset: int8;
      chroma_qp_offset: int8;

      //encoder configuration
      _param: TEncodingParameters;
      stats_file: textfile;

      //classes
      frames: TFrameManager;
      rc: TRatecontrol;
      me: TMotionEstimator;
      me_lowres: TMotionEstimator;
      deblocker: TDeblocker;
{$ifdef DEBUG_Y4M_OUTPUT}
      _y4m_dump: y4m_file;
      _img_dump: TPlanarImage;
{$endif}

      procedure SetISlice;
      procedure SetPSlice;
      procedure RunLowresME;
      function TryEncodeFrame(): boolean;
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

{$ifdef DEBUG_Y4M_OUTPUT}
const
  Y4M_MAGIC   = 'YUV4MPEG2';
  FRAME_MAGIC = 'FRAME'#10;

procedure y4m_open(var f: y4m_file; const filename: string);
var
  s: string;
begin
  AssignFile(f.hnd, filename);
  Rewrite(f.hnd, 1);
  s := format( Y4M_MAGIC + ' W%d H%d F25:1 Ip A1:1'#10, [f.width, f.height] );
  blockwrite(f.hnd, s[1], length(s));
  f.frame_size := f.width * f.height * 3 div 2;
end;

procedure y4m_close (var f: y4m_file);
begin
  CloseFile(f.hnd);
end;

procedure y4m_frame_write(var f: y4m_file; frame: pbyte);
begin
  blockwrite(f.hnd, FRAME_MAGIC, sizeof(FRAME_MAGIC));
  blockwrite(f.hnd, frame^, f.frame_size);
  f.current_frame += 1;
end;
{$endif}


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
  h264s.LoopFilter(param.LoopFilterEnabled, param.FilterOffsetDiv2);

  //allocate frames
  frames := TFrameManager.Create(num_ref_frames, mb_width, mb_height);

  //inter pred
  me := TMotionEstimator.Create(width, height, mb_width, mb_height, h264s);
  me.subme := param.SubpixelMELevel;

  //ratecontrol
  rc := TRatecontrol.Create;
  if param.ABRRateControlEnabled then
      rc.Set2pass(param.Bitrate, param.FrameCount, param.FrameRate, param.stats_1pass_filename)
  else
      rc.SetConstQP(param.QParam);
  chroma_qp_offset := param.ChromaQParamOffset;

  //mb encoder
  case param.AnalysisLevel of
      0: mb_enc := TMBEncoderNoAnalyse.Create;
      1: mb_enc := TMBEncoderQuickAnalyse.Create;
      2: mb_enc := TMBEncoderQuickAnalyseSATD.Create;
  else
      mb_enc := TMBEncoderRDoptAnalyse.Create; //3 and more
      if param.AnalysisLevel > 3 then mb_enc.EnableQuantRefine := true;
  end;
  mb_enc.num_ref_frames := num_ref_frames;
  mb_enc.me := me;
  mb_enc.h264s := h264s;
  mb_enc.chroma_coding := not param.IgnoreChroma;
  mb_enc.LoopFilter := param.LoopFilterEnabled;
  mb_enc.EnablePartitions := (param.PartitionAnalysisLevel > 0) and (param.SubpixelMELevel > 0);

  //lowres ME - fast fullpel luma search, only macroblock MV gets stored
  me_lowres := TMotionEstimator.Create(
                   frames.lowres_mb_width * 16, frames.lowres_mb_height * 16,
                   frames.lowres_mb_width, frames.lowres_mb_height, h264s);
  me_lowres.subme := 0;
  mb_enc_lowres := TMBEncoderLowresRun.Create;
  mb_enc_lowres.me := me_lowres;

  //deblocking filter
  filter_ab_offset := _param.FilterOffsetDiv2 * 2;
  deblocker := TDeblocker.Create(filter_ab_offset);

  //stats
  stats := TCodingStats.Create;
  h264s.SEIString := param.ToString;
  if param.WriteStatsFile then begin
      AssignFile(stats_file, param.stats_filename);
      Rewrite(stats_file);
      writeln(stats_file, h264s.SEIString);
  end;
{$ifdef DEBUG_Y4M_OUTPUT}
  if _param.DumpFrames then begin
      _img_dump := TPlanarImage.Create(width, height);
      _y4m_dump.width := width;
      _y4m_dump.height := height;
      y4m_open(_y4m_dump, 'dump.y4m');
  end;
{$endif}
end;


destructor TFevh264Encoder.Free;
begin
  WriteStats;
  if _param.WriteStatsFile then
      CloseFile(stats_file);
  rc.Free;
  frames.Free;
  me.Free;
  h264s.Free;
  mb_enc.Free;
  me_lowres.Free;
  mb_enc_lowres.Free;
  deblocker.Free;
  stats.Free;
{$ifdef DEBUG_Y4M_OUTPUT}
  if _param.DumpFrames then begin
      _img_dump.Free;
      y4m_close(_y4m_dump);
  end;
{$endif}
end;


procedure TFevh264Encoder.EncodeFrame(const img: TPlanarImage; buffer: pbyte; out stream_size: longword);
begin
  frames.GetFree(fenc);
  fenc.num := frame_num;
  fenc.chroma_qp_offset := chroma_qp_offset;

  frame_copy_image_with_padding(fenc, img);
  frame_lowres_from_input(fenc);

  //set frame params
  if (frame_num = 0) or (frame_num - last_keyframe_num >= key_interval) then
      SetISlice
  else begin
      SetPSlice;
      RunLowresME;
  end;

  //encode frame (or reencode P as I)
  if TryEncodeFrame() = false then begin
      SetISlice;
      TryEncodeFrame();
  end;

  //convert bitstream to bytestream of NAL units
  h264s.GetSliceBytes(buffer, stream_size);

  //stats
  rc.Update(frame_num, stream_size * 8, fenc);
  fenc.stats.size_bytes := stream_size;
  if _param.WriteStatsFile then
      frame_write_stats(stats_file, fenc);
  UpdateStats;

  //prepare reference frame for ME
  frames.InsertRef(fenc);
  LoopfilterDone;
  frame_paint_edges(fenc);
  if _param.SubpixelMELevel > 0 then
      frame_hpel_interpolate(fenc);
  frame_lowres_from_decoded(fenc);

  //done
  frame_num += 1;
  if _param.DumpFrames then
      DumpFrame;
  dsp.FpuReset;
end;

procedure TFevh264Encoder.SetISlice;
begin
  fenc.ftype := SLICE_I;
  last_keyframe_num := frame_num;
end;

procedure TFevh264Encoder.SetPSlice;
begin
  fenc.ftype := SLICE_P;
  fenc.num_ref_frames := min(num_ref_frames, frame_num - last_keyframe_num);
  frames.SetRefs(fenc, frame_num, fenc.num_ref_frames);
  me.NumReferences := fenc.num_ref_frames;
end;

procedure TFevh264Encoder.RunLowresME;
var
  x, y: integer;
begin
  mb_enc_lowres.SetFrame(fenc);
  for y := 0 to (fenc.lowres^.mbh - 1) do begin
      for x := 0 to (fenc.lowres^.mbw - 1) do
          mb_enc_lowres.Encode(x, y);
  end;
end;

function TFevh264Encoder.TryEncodeFrame(): boolean;
var
  x, y: integer;
  slice: TH264Slice;
begin
  result := true;

  //init slice bitstream
  fenc.qp := rc.GetQP(frame_num, fenc.ftype);
  with slice do begin
      type_ := fenc.ftype;
      qp := fenc.qp;
      num_ref_frames := fenc.num_ref_frames;
  end;
  h264s.InitSlice(slice, fenc.bs_buf);

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
var
  mb_i4_count, mb_i16_count: integer;
begin
  result := false;
  if (fenc.ftype = SLICE_I) or (mbrow <= mb_height div 2) then
      exit;

  mb_i4_count  := fenc.stats.mb_type_count[MB_I_4x4];
  mb_i16_count := fenc.stats.mb_type_count[MB_I_16x16];

  if (2 * mb_i4_count > mb_count)
    or (4 * mb_i16_count > 3 * mb_count)
    or (8 * (mb_i4_count + mb_i16_count) > 7 * mb_count)
  then
      result := true;
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
{$ifdef DEBUG_Y4M_OUTPUT}
  frame_copy_decoded_to_image(fenc, _img_dump);
  y4m_frame_write(_y4m_dump, _img_dump.plane[0]);
  exit;
{$endif}
  s := format('fdec%6d', [frame_num]);
  pgm_save(s + '.pgm', fenc.mem[3], fenc.pw, fenc.ph);
  if mb_enc.chroma_coding then begin
      pgm_save(s + '-cr.pgm', fenc.mem[4], fenc.pw div 2, fenc.ph div 2);
      pgm_save(s + '-cb.pgm', fenc.mem[5], fenc.pw div 2, fenc.ph div 2);
  end;

  s := format('fdec%6d lowres', [frame_num]);
  pgm_save(s + '.pgm', fenc.lowres^.mem[3], fenc.lowres^.pw, fenc.lowres^.ph);
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
          DeblockMBRow(mby, fenc, cqp, filter_ab_offset, filter_ab_offset);
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
  //TODO runtime detect
  flags.mmx := true;
  flags.sse2 := true;
  flags.ssse3 := true;
  flags.avx2 := true;
  frame_init(flags);
  intra_pred_init(flags);
  dsp := TDsp.Create(flags);

finalization
  dsp.Free;

end.

