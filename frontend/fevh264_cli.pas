(*******************************************************************************
fevh264_cli.pas
Copyright (c) 2010-2021 David Pethes

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

program fevh264_cli;
{$mode objfpc}{$H+}

uses
  sysutils, math,
  CliParams, yuv4mpeg, pgm,
  image, parameters, encoder, util;
  
var
  frame_limit: integer;
  g_cliopts: TCliOptionHandler;


//this doesn't quite give us the accuracy at high fps, should switch to qpc on windows
function GetMsecs: QWord;
begin
  Result := GetTickCount64;
end;


(* psnr
*)
function ssd2psnr (ssd: int64; pix_count: longword): single;
var
  mse: single;
begin
  mse := ssd * (1 / pix_count);
  if mse > 0 then
      result := 10 * log10(sqr(255) / mse)
  else
      result := 100;
end;


(* help
*)
procedure WriteHelp;
const
  txt: array[0..5] of ansistring = (
    'usage: fevh264_cli [options] input [width height]',
    'accepted input file types:',
    '  - raw YUV 4:2:0 (width and height requied)',
    '  - YUV4MPEG 4:2:0 (*.y4m)',
    '  - Avisynth script (*.avs)',
    'options:'
  );
var
  i: integer;
begin
  for i := 0 to length(txt) - 1 do
      writeln(stdout, txt[i]);
  writeln(stdout, g_cliopts.Descriptions);
end;


procedure FillOptionList;
begin
  with g_cliopts do begin
      AddOption('o', atString, 'output', 'output name');
      AddOption('d', atNone,   'dump',   'save reconstructed frames as *.pgm files');
      AddOption('f', atInt,    'frames', 'encode first n frames only');
      AddOption('h', atNone,   'help',   'print help');

      AddOption('q', atInt,    'qp',     'quantization parameter [21]');
      AddOption('B', atInt,    'bitrate','use average bitrate mode (needs logfile)');
      AddOption('c', atInt,    'chroma-qp-offset', 'chroma QP adjustment [0] (-12..12)');
      AddOption('k', atInt,    'keyint', 'maximum keyframe interval [300]');
      AddOption('m', atInt,    'subme',  'subpixel ME refinement level [3]'
                                         + ' (0=none; 1=hpel; 2=qpel; 3=qpel SATD; 4=qpel chroma SATD; 5=qpel RD)');
      AddOption('r', atInt,    'ref',    'ME reference frame count [1]');
      AddOption('a', atInt,    'analyse','mb type decision quality [2]'
                                         + ' (0=worst; 4=best)');
      AddOption('p', atInt,    'partitions',    'analyze macroblock partitions [1] (0=none, 1=P16x8)');
      AddOption('l', atNone,   'loopfilter',    'enable in-loop deblocking filter');
      AddOption('t', atNone,   'filterthread',  'run deblocking in separate thread');
      AddOption('x', atInt,    'offset-filter', 'alpha/beta offset for deblocking [0]'
                                         + ' (-3=less filtering; 3=more filtering)');
      AddOption('n', atNone,   'no-chroma',  'ignore chroma');
      AddOption('s', atNone,   'stats',  'write statsfile');
      AddOption('S', atString, 'stats-name', 'name for statsfile');
  end;
end;


procedure AssignCliOpts(param: TEncodingParameters; input_filename: string);
begin
  try
    with g_cliopts do begin
      if IsSet('qp') then
          param.QParam := byte( StrToInt(g_cliopts['q']) );
      if IsSet('chroma-qp-offset') then
          param.ChromaQParamOffset := StrToInt(g_cliopts['c']);
      if IsSet('offset-filter') then
          param.FilterOffsetDiv2 := StrToInt(g_cliopts['x']);
      if IsSet('keyint') then
          param.KeyFrameInterval := StrToInt(g_cliopts['k']);
      if IsSet('subme') then
          param.SubpixelMELevel  := StrToInt(g_cliopts['m']);
      if IsSet('analyse') then
          param.AnalysisLevel    := StrToInt(g_cliopts['a']);
      if IsSet('ref') then
          param.NumReferenceFrames := byte( StrToInt(g_cliopts['r']) );
      if IsSet('partitions') then
          param.PartitionAnalysisLevel := byte( StrToInt(g_cliopts['p']) );

      if IsSet('bitrate') then begin
          param.SetABRRateControl( StrToInt(g_cliopts['B']) );
          param.stats_1pass_filename := input_filename + '.1pass.txt';
      end;
      param.AdaptiveQuant     := false;
      param.LoopFilterEnabled := IsSet('loopfilter');
      param.FilterThreadEnabled := IsSet('filterthread');
      param.IgnoreChroma      := IsSet('no-chroma');
      param.WriteStatsFile    := IsSet('stats');
      if param.WriteStatsFile then begin
          if IsSet('stats-name') then
              param.stats_filename := g_cliopts['S']
          else if param.ABRRateControlEnabled then
              param.stats_filename := input_filename + '.2pass.txt'
          else
              param.stats_filename := input_filename + '.1pass.txt';
      end;

      param.DumpFrames := IsSet('dump');
      if IsSet('frames') then
          frame_limit := StrToInt(g_cliopts['f']);
    end;
  except
      on EConvertError do begin
          writeln(stderr, 'bad argument format');
          Halt;
      end;
  end;
end;


function OpenInput(const input_name: string): TAbstractFileReader;
var
  ext: string;
  width, height: integer;
  ok: Boolean;
begin
  ext := ExtractFileExt(input_name);
  if ext = '.avs' then
      result := TAvsReader.Create(input_name)
  else if ext = '.y4m' then
      result := TY4MFileReader.Create(input_name)
  else if g_cliopts.UnparsedCount = 3 then begin
      ok := TryStrToInt(g_cliopts.UnparsedValue(1), width) and TryStrToInt(g_cliopts.UnparsedValue(2), height);
      if not ok then begin
          writeln(stderr, 'invalid width/height');
          Halt;
      end;
      result := TYuvFileReader.Create(input_name, width, height);
  end else
      result := TFFMS2Reader.Create(input_name);
end;


{ encode input to h.264
}
procedure Encode(const input_name, output_name: string);
var
  infile: TAbstractFileReader;
  width, height: integer;
  fps: double;
  frame_count: integer;

  param: TEncodingParameters;
  encoder: TFevh264Encoder;
  pic: TPlanarImage;
  stream_size: longword;
  stream_size_total: int64;
  fout: file;
  buffer: pbyte;

  time_total, time_cur: longword;
  ssd: array[0..2] of Int64;
  psnr_avg: array[0..2] of real;
  kbps: real;
  i: integer;
  encoding_fps: single;

begin
  time_total := 0;
  stream_size_total := 0;
  kbps := 0;
  for i := 0 to 2 do
      psnr_avg[i] := 0;

  //open input
  infile := OpenInput(input_name);
  width  := infile.FrameWidth;
  height := infile.FrameHeight;
  frame_count := infile.FrameCount;
  fps    := infile.FrameRate;
  writeln( format('input: %dx%d @ %.2f fps, %d frames',
                  [width, height, fps, frame_count]) );

  //open output file
  AssignFile(fout, output_name);
  Rewrite   (fout, 1);

  //create encoder
  param := TEncodingParameters.Create(width, height, fps);
  AssignCliOpts(param, infile.Name);
  if (frame_limit > 0) and (frame_limit < frame_count) then
      frame_count := frame_limit;
  param.FrameCount := frame_count;

  encoder := TFevh264Encoder.Create(param);
  buffer := getmem(width * height * 4);

  //encoding loop
  for i := 0 to frame_count - 1 do begin
      //get frame
      pic := infile.ReadFrame;
      time_cur := GetMsecs();

      //encode
      encoder.EncodeFrame(pic, buffer, stream_size);

      //store
      time_total += GetMsecs() - time_cur;
      BlockWrite(fout, buffer^, stream_size);

      //frame stats
      encoder.GetLastFrameSSD(ssd);
      psnr_avg[0] += ssd2psnr(ssd[0], width * height);
      if not param.IgnoreChroma then begin
          psnr_avg[1] += ssd2psnr(ssd[1], width * height div 4);
          psnr_avg[2] += ssd2psnr(ssd[2], width * height div 4);
      end;

      stream_size_total += stream_size;
      kbps := stream_size_total / 1000 * 8 / ((i+1) / fps);

      if time_total > 0 then
          encoding_fps := (i+1) / (time_total/1000)
      else
          encoding_fps := 1000;
      if (encoding_fps < 10) or (i mod 5 = 0) then
          write(format('frame: %5d  psnr: %5.3f  kbps: %7.1f  [%3.1f fps]   '#13, [i, psnr_avg[0]/(i+1), kbps, encoding_fps]));
  end;

  //stream stats
  if time_total = 0 then time_total := 1;

  for i := 0 to 2 do
      psnr_avg[i] := psnr_avg[i] / frame_count;
  kbps := stream_size_total / 1000 * 8 / (frame_count / fps);
  fps  := frame_count / (time_total/1000);

  writeln('average psnr / bitrate / speed:    ',
          format('%.3f dB / %.1f kbps / %4.1f fps', [psnr_avg[0], kbps, fps]) );
  if not param.IgnoreChroma then
      writeln(format('average psnr chroma: %.2f / %.2f dB', [psnr_avg[1], psnr_avg[2]]) );

  //free
  freemem(buffer);
  encoder.Free;
  param.Free;
  CloseFile(fout);
  infile.Free;
end;



(*******************************************************************************
main
*******************************************************************************)
var
  input_name, output_name: string;

begin
  g_cliopts := TCliOptionHandler.Create;
  FillOptionList;
  g_cliopts.ParseFromCmdLine;
  if not g_cliopts.ValidParams then begin
      writeln(stderr, 'Error: ', g_cliopts.GetError);
      Exit;
  end;
  if g_cliopts.IsSet('help') then begin
      WriteHelp;
      Exit;
  end;
  if g_cliopts.UnparsedCount = 0 then begin
      writeln(stderr, 'no input file specified');
      Exit;
  end;

  input_name := g_cliopts.UnparsedValue(0);
  if not FileExists(input_name) then begin
      writeln(stderr, 'input file ' + input_name + ' doesn''t exist');
      halt;
  end;
  if g_cliopts.IsSet('output') then
      output_name := g_cliopts['o']
  else
      output_name := input_name + '.264';

  Encode(input_name, output_name);

  g_cliopts.Free;
  writeln('done.');
end.

