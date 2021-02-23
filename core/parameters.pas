(*******************************************************************************
parameters.pas
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
unit parameters;
{$mode objfpc}{$H+}

interface

uses
  SysUtils, util;

const
  MIN_QP = 0;
  MAX_QP = 51;
  MAX_CHROMA_QP_OFFSET = 12;
  MAX_REFERENCE_FRAMES = 16;

type

  { TEncodingParameters }
  //encoder configuration parameters
  TEncodingParameters = class
    private
      width,
      height: word;            // input dimensions
      frames: longword;        // frame count
      fps: single;             // fps
      qp: byte;                // quantization parameter
      chroma_qp_offset: int8;  // chroma qp offset
      subme: byte;             // subpixel ME refinement
                               { 0 - none (fpel only)
                                 1 - hpel
                                 2 - qpel
                                 3 - qpel SATD
                                 4 - qpel chroma SATD
                                 5 - qpel RD
                               }
      ref: byte;               // reference frame count
      analyse: byte;           // mb type decision quality
                               { 0 - none
                                 1 - heuristics - SAD
                                 2 - heuristics - SATD
                                 3 - rdo
                                 4 - rdo + quant refinement
                               }
      partitions: byte;        // mb partitions to consider 
                               { 0 - none
                                 1 - P16x8
                               }
      key_interval: word;      // maximum keyframe interval
      loopfilter: boolean;     // deblocking
      filter_thread: boolean;  // deblocking in separate thread
      filter_offset_div2: int8;// alpha/beta offset div 2
      aq: boolean;             // mb-level adaptive quantization
      luma_only: boolean;      // ignore chroma
      dump_decoded_frames: boolean;  //store decoded frames to disk (pgm or y4m)

      rc: record
          enabled: boolean;    // enable avg. bitrate ratecontrol
          bitrate: longword;   // desired bitrate in kbps
      end;
      procedure SetAnalysisLevel(const AValue: byte);
      procedure SetChromaQParamOffset(const AValue: int8);
      procedure SetFilterOffset(AValue: int8);
      procedure SetFilterThreadEnabled(AValue: boolean);
      procedure SetKeyFrameInterval(const AValue: word);
      procedure SetNumReferenceFrames(const AValue: byte);
      procedure SetPartitions(AValue: byte);
      procedure SetQParam(const AValue: byte);
      procedure SetSubpixelMELevel(const AValue: byte);
      procedure ValidateQParams;
      procedure ValidateSubME;
    public
      WriteStatsFile: boolean;  // write frame statistics to statfile
      stats_filename: string;  // statfile name
      stats_1pass_filename: string;  // stats from 1st pass for ABR RC

      property FrameWidth: word read width;
      property FrameHeight: word read height;
      property FrameRate: single read fps;

      property ABRRateControlEnabled: boolean read rc.enabled;
      property FrameCount: longword read frames write frames;
      property Bitrate: longword read rc.bitrate;

      property QParam: byte read qp write SetQParam;
      property ChromaQParamOffset: int8 read chroma_qp_offset write SetChromaQParamOffset;
      property KeyFrameInterval: word read key_interval write SetKeyFrameInterval;

      property LoopFilterEnabled: boolean read loopfilter write loopfilter;
      property FilterThreadEnabled: boolean read filter_thread write SetFilterThreadEnabled;
      property FilterOffsetDiv2: int8 read filter_offset_div2 write SetFilterOffset;

      property AnalysisLevel: byte read analyse write SetAnalysisLevel;
      property PartitionAnalysisLevel: byte read partitions write SetPartitions;
      property SubpixelMELevel: byte read subme write SetSubpixelMELevel;
      property NumReferenceFrames: byte read ref write SetNumReferenceFrames;
      property AdaptiveQuant: boolean read aq write aq;

      property IgnoreChroma: boolean read luma_only write luma_only;
      property DumpFrames: boolean read dump_decoded_frames write dump_decoded_frames;

      constructor Create;
      constructor Create(const width_, height_: word; const fps_: double);
      procedure SetABRRateControl(const bitrate_: longword);
      procedure SetStreamParams(const width_,height_,frame_count:integer; const fps_:single);
      function ToString: string; override;
  end;

implementation

{ TEncodingParameters }

procedure TEncodingParameters.SetAnalysisLevel(const AValue: byte);
begin
  analyse := clip3(0, AValue, 4);
end;

procedure TEncodingParameters.SetChromaQParamOffset(const AValue: int8);
begin
  chroma_qp_offset := clip3(-MAX_CHROMA_QP_OFFSET, AValue, MAX_CHROMA_QP_OFFSET);
  ValidateQParams;
end;

procedure TEncodingParameters.SetFilterOffset(AValue: int8);
begin
  filter_offset_div2 := clip3(-3, AValue, 3);
end;

procedure TEncodingParameters.SetFilterThreadEnabled(AValue: boolean);
begin
  filter_thread := AValue;
  if AValue then
      LoopFilterEnabled := true;
end;

procedure TEncodingParameters.SetKeyFrameInterval(const AValue: word);
begin
  key_interval := AValue;
  if key_interval = 0 then key_interval := 1;
end;

procedure TEncodingParameters.ValidateQParams;
begin
  if qp + chroma_qp_offset > MAX_QP then
      chroma_qp_offset := MAX_QP - qp;
  if qp + chroma_qp_offset < MIN_QP then
      chroma_qp_offset := MIN_QP - qp;
end;

procedure TEncodingParameters.ValidateSubME;
begin
  if (ref > 1) and (subme < 2) then
      subme := 2;
end;

constructor TEncodingParameters.Create;
begin
  Create(320, 240, 25.0);
end;

procedure TEncodingParameters.SetNumReferenceFrames(const AValue: byte);
begin
  ref := clip3(1, AValue, MAX_REFERENCE_FRAMES);
  ValidateSubME;
end;

procedure TEncodingParameters.SetPartitions(AValue: byte);
begin
  partitions := clip3(0, AValue, 1);
end;

procedure TEncodingParameters.SetQParam(const AValue: byte);
begin
  qp := clip3(MIN_QP, AValue, MAX_QP);
  ValidateQParams;
end;

procedure TEncodingParameters.SetSubpixelMELevel(const AValue: byte);
begin
  subme := clip3(0, AValue, 5);
  ValidateSubME;
end;

constructor TEncodingParameters.Create(const width_, height_: word; const fps_: double);
begin
  width := width_;
  height := height_;
  fps := fps_;

  qp := 21;
  chroma_qp_offset := 0;
  key_interval := 300;
  subme := 3;
  ref := 1;
  analyse := 2;
  partitions := 1;
  rc.enabled := false;
  aq := false;
  loopfilter := false;
  filter_thread := false;
  filter_offset_div2 := 0;
  luma_only := false;
  WriteStatsFile := false;
  stats_filename := 'fevh264log.txt';
  stats_1pass_filename := stats_filename;
  frames := 0;
end;

procedure TEncodingParameters.SetABRRateControl(const bitrate_: longword);
begin
  rc.enabled := true;
  rc.bitrate := bitrate_;
end;

procedure TEncodingParameters.SetStreamParams(const width_, height_, frame_count: integer; const fps_: single);
begin
  width := width_;
  height := height_;
  frames := frame_count;
  fps := fps_;
end;

function TEncodingParameters.ToString: string;
const
  b2s: array[false..true] of char = ('0', '1');
begin
  Result := format(
    'options: keyint:%d qp:%d subme:%d analyse:%d ref:%d chroma_qp_offset:%d deblock:%s (offset:%d threaded:%s)',
    [key_interval, qp, subme, analyse, ref, chroma_qp_offset, b2s[loopfilter], filter_offset_div2, b2s[filter_thread]]
  );
end;

end.

