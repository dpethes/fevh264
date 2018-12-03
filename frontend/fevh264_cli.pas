(*******************************************************************************
fevh264_cli.pas
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

program fevh264_cli;
{$mode objfpc}{$H+}

uses
  sysutils, Classes, CliParamHandler, math,
  yuv4mpeg, pgm,
  image, parameters, encoder, util;
  
var
  foutput: string;
  dump: boolean;
  frames: integer;
  options: TCliOptionHandler;


(* get_msecs
   return time in miliseconds
*)
function get_msecs: longword;
var
  h, m, s, ms: word;
begin
  DecodeTime (Now(), h, m, s, ms);
  Result := (h * 3600*1000 + m * 60*1000 + s * 1000 + ms);
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
  writeln(stdout, options.GetDescriptions);
end;


procedure FillOptionList;
begin
  with options do begin
      AddOption('o', atString, 'output', 'output name');
      AddOption('d', atNone,   'dump',   'save reconstructed frames as *.pgm files');
      AddOption('f', atInt,    'frames', 'encode first n frames only');
      AddOption('h', atNone,   'help',   'print help');

      AddOption('q', atInt,    'qp',     'quantization parameter [21]');
      AddOption('B', atInt,    'bitrate','use average bitrate mode (needs logfile)');
      AddOption('c', atInt,    'chroma-qp-offset', 'chroma QP adjustment [0]');
      AddOption('k', atInt,    'keyint', 'maximum keyframe interval [300]');
      AddOption('m', atInt,    'subme',  'subpixel ME refinement level [3]'
                                         + ' (0=none; 1=hpel; 2=qpel; 3=qpel SATD; 4=qpel chroma SATD)');
      AddOption('a', atInt,    'analyse','mb type decision quality [2]'
                                         + ' (0=worst; 3=best)');
      AddOption('r', atInt,    'ref',    'reference frame count [1]');
      AddOption('l', atNone,   'loopfilter', 'enable in-loop deblocking filter');
      AddOption('t', atNone,   'filterthread', 'use separate thread for deblocking filter');
      AddOption('n', atNone,   'no-chroma',  'ignore chroma');
      AddOption('s', atNone,   'stats',  'write statsfile');
      AddOption('S', atString, 'stats-name', 'name for statsfile');
  end;
end;


procedure AssignCliOpts(param: TEncodingParameters; input_filename: string);
begin
  try
      if options.IsSet('qp') then
          param.QParam := byte( StrToInt(options['q']) );
      if options.IsSet('chroma-qp-offset') then
          param.ChromaQParamOffset := byte( StrToInt(options['c']) );
      if options.IsSet('keyint') then
          param.KeyFrameInterval := StrToInt(options['k']);
      if options.IsSet('subme') then
          param.SubpixelMELevel  := StrToInt(options['m']);
      if options.IsSet('analyse') then
          param.AnalysisLevel    := StrToInt(options['a']);
      if options.IsSet('ref') then
          param.NumReferenceFrames := byte( StrToInt(options['r']) );
      if options.IsSet('bitrate') then begin
          param.SetABRRateControl( StrToInt(options['B']) );
          param.stats_1pass_filename := input_filename + '.1pass.txt';
      end;
      param.AdaptiveQuant     := false;
      param.LoopFilterEnabled := options.IsSet('loopfilter');
      param.FilterThreadEnabled := options.IsSet('filterthread');
      param.IgnoreChroma      := options.IsSet('no-chroma');
      param.WriteStatsFile    := options.IsSet('stats');
      if param.WriteStatsFile then begin
          if options.IsSet('stats-name') then
              param.stats_filename := options['S']
          else if param.ABRRateControlEnabled then
              param.stats_filename := input_filename + '.2pass.txt'
          else
              param.stats_filename := input_filename + '.1pass.txt';
      end;

      dump := options.IsSet('dump');
      if options.IsSet('frames') then
          frames := StrToInt(options['f']);
  except
      on e: EParserError do begin
          writeln('error while parsing arguments: ' + e.Message);
          Halt;
      end;
      on EConvertError do begin
          writeln(stderr, 'bad argument format');
          Halt;
      end;
  end;
end;


function OpenInput: TAbstractFileReader;
var
  input: string;
  ext: string;
  width, height: integer;
begin
  if (options.GetUnparsedParams).Count = 0 then begin
      writeln(stderr, 'no input file specified');
      halt;
  end;
  input := options.GetUnparsed(0);
  if not FileExists(input) then begin
      writeln('input file ' + input + ' doesn''t exist');
      halt;
  end;

  ext := Copy(input, length(input) - 3, length(input));
  if ext = '.avs' then
      result := TAvsReader.Create(input)
  else if ext = '.y4m' then
      result := TY4MFileReader.Create(input)
  else begin
      try
          width  := StrToInt( options.GetUnparsed(1) );
          height := StrToInt( options.GetUnparsed(2) );
      except
          on EConvertError do begin
              writeln(stderr, 'invalid width/height');
              Halt;
          end;
      end;
      result := TYuvFileReader.Create(input, width, height);
  end;

  if options.IsSet('output') then
      foutput := options['o']
  else
      foutput := input + '.264';
end;


{ encode input to h.264
}
procedure Encode;
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

begin
  time_total := 0;
  stream_size_total := 0;
  kbps := 0;
  for i := 0 to 2 do
      psnr_avg[i] := 0;

  //open input
  infile := OpenInput;
  width  := infile.FrameWidth;
  height := infile.FrameHeight;
  frame_count := infile.FrameCount;
  fps    := infile.FrameRate;
  writeln( format('input: %dx%d @ %.2f fps, %d frames',
                  [width, height, fps, frame_count]) );

  //open output file
  AssignFile(fout, foutput);
  Rewrite   (fout, 1);

  //create encoder
  param := TEncodingParameters.Create(width, height, fps);
  AssignCliOpts(param, infile.Name);
  if (frames > 0) and (frames < frame_count) then
      frame_count := frames;
  param.FrameCount := frame_count;

  encoder := TFevh264Encoder.Create(param);
  encoder.dump_decoded_frames := dump;
  buffer := getmem(width * height * 4);

  //encoding loop
  for i := 0 to frame_count - 1 do begin
      //get frame
      pic := infile.ReadFrame;
      time_cur := get_msecs();

      //encode
      encoder.EncodeFrame(pic, buffer, stream_size);

      //store
      time_total += get_msecs() - time_cur;
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
      write( format('frame: %6d  psnr: %5.2f  kbps: %7.1f',
                     [i, psnr_avg[0] / (i + 1), kbps]), #13 );
  end;
  writeln;

  //stream stats
  if time_total = 0 then time_total := 1;

  for i := 0 to 2 do
      psnr_avg[i] := psnr_avg[i] / frame_count;
  kbps := stream_size_total / 1000 * 8 / (frame_count / fps);
  fps  := frame_count / (time_total/1000);

  write  ('average psnr / bitrate / speed:    ');
  writeln(format('%.2f dB / %.1f kbps / %4.1f fps', [psnr_avg[0], kbps, fps]) );
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
begin
  options := TCliOptionHandler.Create;
  FillOptionList;
  options.ParseParameters;
  if options.IsSet('help') then begin
      WriteHelp
  end else
      Encode;
  options.Free;
  writeln('done.');
end.

