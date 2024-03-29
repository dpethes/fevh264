(*******************************************************************************
yuv4mpeg.pas
Copyright (c) 2010-2018 David Pethes

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

(*
YUV format reading/writing functions (YUV 420 expected)
input: YUV4MPEG files, raw yuv, Avisynth scripts

YUV4MPEG2 description:
  http://wiki.multimedia.cx/index.php?title=YUV4MPEG2

To create a YUV4MPEG2 file from an ordinary video file, you can use mplayer
(http://www.mplayerhq.hu):
mplayer video.avi -vo yuv4mpeg -benchmark

Avisynth reading inspired by x264.
*)

unit yuv4mpeg;
{$mode objfpc}
{$H+}

interface

uses
  sysutils, image
  {$ifdef windows}, vfw {$endif}
  {$ifdef HAS_FFMS2}, ffms {$endif}
  ;


type

  { TAbstractFileReader }

  TAbstractFileReader = class
  private
    function GetCurrentFrame: longword;
    function GetFrameCount: longword;
    function GetFrameHeight: word;
    function GetFrameRate: double;
    function GetFrameWidth: word;
    protected
      width, height: word;
      frame_count,
      current_frame: longword;
      frame_rate: double;
      _filename: string;
    public
      property Name: string read _filename;
      property FrameWidth: word read GetFrameWidth;
      property FrameHeight: word read GetFrameHeight;
      property FrameCount: longword read GetFrameCount;
      property CurrentFrame: longword read GetCurrentFrame;
      property FrameRate: double read GetFrameRate;
      function ReadFrame: TPlanarImage; virtual; abstract;
  end;

  { TY4MFileReader }

  TY4MFileReader = class(TAbstractFileReader)
    private
      fileHandle: file;
      file_header_size,
      frame_header_size: word;
      frame_size: longword;
      img: TPlanarImage;
      function ParseHeader: boolean;
    public
      constructor Create(const filename: string);
      destructor Destroy; override;
      function ReadFrame: TPlanarImage; override;
  end;

  { TYuvFileReader }

  TYuvFileReader = class(TAbstractFileReader)
    private
      fileHandle: file;
      frame_size: longword;
      img: TPlanarImage;
    public
      constructor Create(const filename: string; const width_, height_: word);
      destructor Destroy; override;
      function ReadFrame: TPlanarImage; override;
  end;

{$ifdef windows}
  { TAvsReader }

  TAvsReader = class(TAbstractFileReader)
    private
      p_avi: IAVIStream;
      frame_size: longword;
      img: TPlanarImage;
    public
      constructor Create(const filename: string);
      destructor Destroy; override;
      function ReadFrame: TPlanarImage; override;
  end;
{$else}
  TAvsReader = TY4MFileReader;
{$endif}

{$ifdef HAS_FFMS2}
  { TFFMS2Reader }

  TFFMS2Reader = class(TAbstractFileReader)
    private
      videosource: PFFMS_VideoSource;
      errinfo: FFMS_ErrorInfo;
      error_buffer: array[0..1023] of char;
      last_progress: integer;
      img: TPlanarImage;
    public
      constructor Create(const filename: string);
      destructor Destroy; override;
      function ReadFrame: TPlanarImage; override;
  end;
{$else}
  TFFMS2Reader = TY4MFileReader;
{$endif}



(*******************************************************************************
*******************************************************************************)
implementation

const
  Y4M_MAGIC   = 'YUV4MPEG2';
  FRAME_MAGIC = 'FRAME'#10;
  Y4M_FRAME_HEADER_SIZE = length(FRAME_MAGIC);


{ TYuvFileReader }

constructor TYuvFileReader.Create(const filename: string; const width_, height_: word);
begin
  _filename := filename;
  frame_count := 0;
  current_frame := 0;

  AssignFile(fileHandle, filename);
  Reset(fileHandle, 1);

  width  := width_;
  height := height_;
  frame_size  := width * height + (width * height div 2);
  frame_count := FileSize(fileHandle) div frame_size;
  frame_rate := 25;

  img := TPlanarImage.Create(width, height);
end;

destructor TYuvFileReader.Destroy;
begin
  img.Free;
  CloseFile(fileHandle);
end;

function TYuvFileReader.ReadFrame: TPlanarImage;
begin
  blockread(fileHandle, img.plane[0]^, frame_size);
  current_frame += 1;
  img.frame_num := current_frame;
  result := img;
end;



{ TY4MFileReader }

function TY4MFileReader.ParseHeader: boolean;
const
  MINSIZE = 36;  //~ minimal header with single frame
var
  i, num, denom: integer;
  c, param_c: char;
  s: string;
  filemagic_buffer: array[0..9] of byte;
begin
  result := false;
  if FileSize(fileHandle) < MINSIZE then
      exit;

  blockread(fileHandle, filemagic_buffer[0], Length(Y4M_MAGIC) + 1);
  filemagic_buffer[9] := 0;
  s := pchar(@filemagic_buffer[0]);
  if s <> Y4M_MAGIC then
      exit;

  param_c := ' ';
  c := ' ';
  repeat
      blockread(fileHandle, param_c, 1);
      s := '';
      blockread(fileHandle, c, 1);
      repeat
          s += c;
          blockread(fileHandle, c, 1);
      until (c = #10) or (c = ' ');
      case param_c of
        'W':
          width  := word( StrToInt(s) );
        'H':
          height := word( StrToInt(s) );
        'F':
            begin
              i := Pos(':', s);
              num := StrToInt( Copy(s, 0, i-1) );
              Delete(s, 1, i);
              denom := StrToInt( s );
              frame_rate := num / denom;
            end;
      end;
  until c = #10;

  file_header_size  := FilePos(fileHandle);
  frame_header_size := 6;
  result := true;
end;

constructor TY4MFileReader.Create(const filename: string);
begin
  _filename := filename;
  frame_count := 0;
  current_frame := 0;

  AssignFile(fileHandle, filename);
  Reset(fileHandle, 1);
  if not ParseHeader then
      raise EFormatError.Create('Not a Y4M file');

  frame_size  := width * height + (width * height div 2);
  frame_count := (FileSize(fileHandle) - file_header_size) div (Y4M_FRAME_HEADER_SIZE + int64(frame_size));

  img := TPlanarImage.Create(width, height);
end;

destructor TY4MFileReader.Destroy;
begin
  img.Free;
  CloseFile(fileHandle);
end;

function TY4MFileReader.ReadFrame: TPlanarImage;
begin
  blockread(fileHandle, img.plane[0]^, Y4M_FRAME_HEADER_SIZE); //trash bytes
  blockread(fileHandle, img.plane[0]^, frame_size);
  current_frame += 1;
  img.frame_num := current_frame;
  result := img;
end;


{ TAvsReader }
{$ifdef windows}
constructor TAvsReader.Create(const filename: string);
var
  info: TAVIStreamInfo;
  i: byte;
begin
  _filename := filename;
  AVIFileInit;

  //mode: OF_READ = 0 {windows.pas}
  if AVIStreamOpenFromFile( p_avi, pchar(filename), streamtypeVIDEO, 0, 0, nil ) <> 0 then begin
      AVIFileExit;
      writeln('AVIStreamOpenFromFile failed');
      exit;
  end;

  if AVIStreamInfo( p_avi, info, sizeof(TAVIStreamInfo) ) <> 0 then begin
      AVIStreamRelease(p_avi);
      AVIFileExit;
      writeln('AVIStreamInfo failed');
      exit;
  end;

  // check input format
  if info.fccHandler <> MKFOURCC('Y', 'V', '1', '2') then begin
      AVIStreamRelease(p_avi);
      AVIFileExit;
      write('unsupported input format: ');
      for i := 0 to 3 do write( char( info.fccHandler shr (i * 8)) );
      writeln;
      exit;
  end;

  width  := info.rcFrame.right - info.rcFrame.left;
  height := info.rcFrame.bottom - info.rcFrame.top;
  frame_count := info.dwLength;
  current_frame := 0;
  frame_rate := info.dwRate / info.dwScale;
  frame_size  := width * height + (width * height div 2);

  img := TPlanarImage.Create(width, height);
  img.SwapUV;
end;

destructor TAvsReader.Destroy;
begin
  AVIStreamRelease(p_avi);
  AVIFileExit;
  img.Free;
end;

function TAvsReader.ReadFrame: TPlanarImage;
var
  res: integer;
begin
  res := AVIStreamRead(p_avi, current_frame, 1, img.plane[0], frame_size, nil, nil);
  if res <> 0 then
      writeln('AVIStreamRead failed: ' + IntToStr(res));
  current_frame += 1;
  result := img;
end;
{$endif}

{$ifdef HAS_FFMS2}
{ TFFMS2Reader }

function IndexerProgressCallback(Current: int64; Total: int64; ICPrivate: pointer): integer; {$IFDEF Windows} stdcall; {$endif}
var
  h: TFFMS2Reader;
  p: integer;
begin
  h := TFFMS2Reader(ICPrivate);
  p := round(Current/Total*100);
  if h.last_progress <> p then begin
      write(format('indexing %d', [p]), '%'+#13);
      h.last_progress := p;
  end;
  result := 0;
end;

constructor TFFMS2Reader.Create(const filename: string);
var
  indexer: PFFMS_Indexer;
  index: PFFMS_Index;
  trackno: LongInt;
  videoprops: PFFMS_VideoProperties;
  propframe: PFFMS_Frame;

begin
  _filename := filename;
  FFMS_Init();

  errinfo.Buffer := @error_buffer[0];
  errinfo.BufferSize := SizeOf(error_buffer);
  errinfo.ErrorType  := ord(FFMS_ERROR_SUCCESS);
  errinfo.SubType    := ord(FFMS_ERROR_SUCCESS);

  indexer := FFMS_CreateIndexer(PChar(filename), @errinfo);
  if indexer = nil then begin
      writeln('FFMS_CreateIndexer failed');
      halt;
  end;

  FFMS_SetProgressCallback(indexer, @IndexerProgressCallback, self);
  index := FFMS_DoIndexing2(indexer, ord(FFMS_IEH_ABORT), @errinfo);
  if index = nil then begin
      writeln('FFMS_DoIndexing2 failed');
      halt;
  end;

  //Retrieve the track number of the first video track
  trackno := FFMS_GetFirstTrackOfType(index, ord(FFMS_TYPE_VIDEO), @errinfo);
  if trackno < 0 then begin
      //no video tracks found in the file, this is bad and you should handle it
      writeln('FFMS_GetFirstTrackOfType failed');
      halt;
  end;

  videosource := FFMS_CreateVideoSource(PChar(filename), trackno, index, 1, ord(FFMS_SEEK_NORMAL), @errinfo);
  if videosource = nil then begin
      writeln('FFMS_CreateVideoSource failed');
      halt;
  end;

  FFMS_DestroyIndex(index);

  videoprops := FFMS_GetVideoProperties(videosource);
  propframe := FFMS_GetFrame(videosource, 0, @errinfo);

  //Assert(propframe^.ColorSpace = 0);
  Assert(propframe^.Linesize[1] = propframe^.Linesize[2]);

  frame_count := videoprops^.NumFrames;
  width  := propframe^.EncodedWidth;
  height := propframe^.EncodedHeight;
  frame_rate := videoprops^.FPSNumerator / videoprops^.FPSDenominator;
  current_frame := 0;
  last_progress := 0;

  img := TPlanarImage.Create(width, height, propframe^.Linesize[0], propframe^.Linesize[1]);
end;

destructor TFFMS2Reader.Destroy;
begin
  img.Free;
  FFMS_DestroyVideoSource(videosource);
end;

function TFFMS2Reader.ReadFrame: TPlanarImage;
var
  f: PFFMS_Frame;
begin
  f := FFMS_GetFrame(videosource, current_frame, @errinfo);
  if f = nil then begin
      writeln('FFMS_GetFrame failed');
      halt;
  end;
  current_frame += 1;
  move(f^.Data[0]^, img.plane[0]^, img.Height * img.stride);
  move(f^.Data[1]^, img.plane[1]^, img.Height div 2 * img.stride_c);
  move(f^.Data[2]^, img.plane[2]^, img.Height div 2 * img.stride_c);
  result := img;
end;
{$endif}

{ TAbstractFileReader }

function TAbstractFileReader.GetCurrentFrame: longword;
begin
  result := CurrentFrame;
end;

function TAbstractFileReader.GetFrameCount: longword;
begin
  result := frame_count;
end;

function TAbstractFileReader.GetFrameHeight: word;
begin
  result := height;
end;

function TAbstractFileReader.GetFrameRate: double;
begin
  result := frame_rate;
end;

function TAbstractFileReader.GetFrameWidth: word;
begin
  result := width
end;


end.

