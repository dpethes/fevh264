(*******************************************************************************
fmain.pas
Copyright (c) 2011 David Pethes

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

unit fmain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, StdCtrls, Spin, ExtCtrls,
  LCLType, IntfGraphics, GraphType, math,
  common, image, parameters, frame, yuv4mpeg, encoder;

type
  //signals for EncodeFrames loop
  TFrameEncoderSignal = (FESNone, FESEncode, FESEncodeOne, FESStop, FESPause);
  //gui enc state
  TEncodeState = (ESEncoding, ESPaused, ESFinished, ESStopped);

  { TForm1 }

  TForm1 = class(TForm)
    BOpenInput: TButton;
    BSelectStatsFile: TButton;
    BStart: TButton;
    BPause: TButton;
    BNextFrame: TButton;
    BStopEncoding: TButton;
    BSaveScreenshot: TButton;
    CBAnalyse: TComboBox;
    CBSubME: TComboBox;
    CBNoChroma: TCheckBox;
    CBStats: TCheckBox;
    CBDisplayLuma: TCheckBox;
    CBVisualize: TCheckBox;
    CBLoopFilter:TCheckBox;
    CheckBoxPauseOnKey: TCheckBox;
    EditStatsFile: TEdit;
    EditBitrate: TEdit;
    EditInput: TEdit;
    ImageFenc: TImage;
    Label1: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    Label4: TLabel;
    Label5: TLabel;
    OpenDialogInput: TOpenDialog;
    RBRC2pass: TRadioButton;
    RBQP: TRadioButton;
    ScrollBoxImageFenc: TScrollBox;
    SpinEditRefFrames: TSpinEdit;
    SpinEditKeyInt: TSpinEdit;
    SpinEditQP: TSpinEdit;
    StaticTextProgress: TStaticText;
    StaticTextInputInfo: TStaticText;
    procedure BNextFrameClick(Sender: TObject);
    procedure BOpenInputClick(Sender: TObject);
    procedure BStartClick(Sender: TObject);
    procedure BPauseClick(Sender: TObject);
    procedure BStopEncodingClick(Sender: TObject);
    procedure BSaveScreenshotClick(Sender: TObject);
    procedure CBAnalyseChange(Sender: TObject);
    procedure CBLoopFilterChange(Sender:TObject);
    procedure CBNoChromaChange(Sender: TObject);
    procedure CBStatsChange(Sender: TObject);
    procedure CBSubMEChange(Sender: TObject);
    procedure CBVisualizeChange(Sender: TObject);
    procedure CheckBoxPauseOnKeyChange(Sender: TObject);
    procedure EditBitrateChange(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure RBQPChange(Sender: TObject);
    procedure RBRC2passChange(Sender: TObject);
    procedure SpinEditKeyIntChange(Sender: TObject);
    procedure SpinEditQPChange(Sender: TObject);
    procedure SpinEditRefFramesChange(Sender: TObject);
  private
    { private declarations }
    param: TEncodingParameters;
    encoder: TFevh264Encoder;
    pic: TPlanarImage;
    buffer: pbyte;
    frame: frame_t;

    frame_num: integer;
    stream_size_total: int64;
    time_total: integer;

    input, output: string;
    fwidth, fheight, frame_count: integer;
    fps: double;
    infile: TAbstractFileReader;
    fout: file;

    input_opened, output_opened, encoder_allocated: boolean;
    pause_on_key: Boolean;
    frame_enc_signal: TFrameEncoderSignal;
    enc_state: TEncodeState;

    screenshot_counter: integer;

    function CreateInputReader(const inputFileName: string): TAbstractFileReader;
    procedure OpenInput;
    procedure OpenOutput;
    procedure CreateEncoder;
    procedure CloseInput;
    procedure CloseOutput;
    procedure FreeEncoder;
    procedure EncodeFrame(const i: integer);  //process signals
    procedure EncodeFrames;
    procedure EncodeInit;
    procedure EncodeFree;
    procedure DrawFrameEncoded;
    procedure SetImageArea;
  public
    { public declarations }
  end; 

var
  Form1: TForm1; 

//******************************************************************************
implementation

function get_msecs: longword;
var
  h, m, s, ms: word;
begin
  DecodeTime (Now(), h, m, s, ms);
  Result := h * 3600*1000 + m * 60*1000 + s * 1000 + ms;
end;

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


const
  UV_CSPC: array[0..3] of real = (1.4020, -0.3441, -0.7141, 1.7720); //CCIR 601-1
  //UV_CSPC: array[0..3] of real = (1.5701, -0.1870, -0.4664, 1.8556); //ITU.BT-709

var
  lookup_table: array [0..3] of pinteger;

(* lookup table alloc & init *)
procedure BuildLut();
var
  c, j: integer;
  v: single;
begin
  for c := 0 to 3 do
      getmem (lookup_table[c], 256 * 4);
  for c := 0 to 255 do begin
      v := c - 128;
      for j := 0 to 3 do
          lookup_table[j][c] := integer( round( v * UV_CSPC[j] ) );
  end;
end;

//conversion works on 2x2 pixels at once, since they share chroma info
procedure cspc_yv12_to_rgba32 (pict: TLazIntfImage; const fenc: frame_t);
var
  y, x: integer;
  p, pu, pv, t: pbyte;         //source plane ptrs
  stride, stride_cr: integer;
  d: integer;               //dest index for topleft pixel
  r0, r1, r2, r4: integer;  //scaled yuv values for rgb calculation
  t0, t1, t2, t3: pinteger; //lookup table ptrs
  row1, row2: PRGBAQuad;

function clip (c: integer): byte; inline;
  begin
      Result := byte (c);
      if c > 255 then
          Result := 255
      else
          if c < 0 then Result := 0;
  end;

begin
  t0 := lookup_table[0];
  t1 := lookup_table[1];
  t2 := lookup_table[2];
  t3 := lookup_table[3];

  p  := fenc.plane_dec[0];
  pu := fenc.plane_dec[1];
  pv := fenc.plane_dec[2];
  stride    := fenc.stride;
  stride_cr := fenc.stride_c;

  for y := 0 to pict.Height shr 1 - 1 do begin

      row1 := PRGBAQuad( pict.GetDataLineStart(y * 2) );
      row2 := PRGBAQuad( pict.GetDataLineStart(y * 2 + 1) );

      for x := 0 to pict.Width shr 1 - 1 do begin
          d := x * 2;  //row start relative index
          r0 := t0[ (pv + x)^ ];  //chroma
          r1 := t1[ (pu + x)^ ] + t2[ (pv + x)^ ];
          r2 := t3[ (pu + x)^ ];
          t := p + d;  //upper left luma

          //upper left/right luma
          r4 := t^;
          {$ifdef LUMA_FULL} r4 := round( (255/219) * (r4 - 16) ); {$endif}
          row1[d].Red   := clip( r4 + r0 );
          row1[d].Green := clip( r4 + r1 );
          row1[d].Blue  := clip( r4 + r2 );
          row1[d].Alpha := 255;

          r4 := (t + 1)^;
          {$ifdef LUMA_FULL} r4 := round( (255/219) * (r4 - 16) ); {$endif}
          row1[d+1].Red   := clip( r4 + r0 );
          row1[d+1].Green := clip( r4 + r1 );
          row1[d+1].Blue  := clip( r4 + r2 );
          row1[d+1].Alpha := 255;

          //lower left/right luma
          r4 := (t + stride)^;
          {$ifdef LUMA_FULL} r4 := round( (255/219) * (r4 - 16) ); {$endif}
          row2[d].Red   := clip( r4 + r0 );
          row2[d].Green := clip( r4 + r1 );
          row2[d].Blue  := clip( r4 + r2 );
          row2[d].Alpha := 255;

          r4 := (t + 1 + stride)^;
          {$ifdef LUMA_FULL} r4 := round( (255/219) * (r4 - 16) ); {$endif}
          row2[d+1].Red   := clip( r4 + r0 );
          row2[d+1].Green := clip( r4 + r1 );
          row2[d+1].Blue  := clip( r4 + r2 );
          row2[d+1].Alpha := 255;
      end;

      p  += stride * 2;
      pu += stride_cr;
      pv += stride_cr;
  end;
end;

//******************************************************************************
(*
draw_line
modified SDL_DrawLine() from jedi-sdl/sdlutils.pas
*)
procedure draw_line(plane: pbyte; width, height, x1, y1, x2, y2: integer);
var
  dx, dy, sdx, sdy, x, y, px, py: integer;
  pos: integer;

procedure color (var c: byte); inline;
begin
  if c < 192 then
      c := 255
  else
      c := 0;
end;

begin
  //shortcut: point
  if (x1 = x2) and (y1 = y2) then begin
      if (x1 < width) and (y1 < height) then begin
          pos := y2 * width + x2;
          color(plane[pos]);
      end;
      Exit;
  end;

  dx := x2 - x1;
  dy := y2 - y1;
  if dx < 0 then
      sdx := -1
  else
      sdx := 1;
  if dy < 0 then
      sdy := -1
  else
      sdy := 1;
  dx := sdx * dx + 1;
  dy := sdy * dy + 1;
  x := 0;
  y := 0;
  px := x1;
  py := y1;
  if dx >= dy then begin
      for x := 0 to dx - 1 do begin
          if (px >= width) or (py >= height) then continue;
          pos := py * width + px;
          color(plane[pos]);
          y := y + dy;
          if y >= dx then begin
              y := y - dx;
              py := py + sdy;
          end;
          px := px + sdx;
      end;
  end
  else begin
      for y := 0 to dy - 1 do begin
          if (px >= width) or (py >= height) then continue;
          pos := py * width + px;
          color(plane[pos]);
          x := x + dx;
          if x >= dy then begin
              x := x - dy;
              px := px + sdx;
          end;
          py := py + sdy;
      end;
  end;
end;



(*
draw 8x8 square to plane
  inner 6x6 square is filled with selected color, edge pixels are set to gray
*)
type
  draw_square_func_t = procedure(p: pbyte; stride, height: integer; x, y: word; val: byte);

procedure draw_square_fast(p: pbyte; stride, height: integer; x, y: word; val: byte);
var
   i: integer;
   c, d: int64;
begin
   p += y * stride + x;
   //one block line, edge pixels uncolored
   d := $8080808080808080;
   c := int64(128 shl 24 + val shl 16 + val shl 8 + val) shl 32
              + val shl 24 + val shl 16 + val shl 8 + 128;
   pint64(p)^ := d;
   p += stride;
   for i := 0 to 5 do begin
       pint64(p)^ := c;
       p += stride;
   end;
   pint64(p)^ := d;
end;

procedure draw_square_slow(p: pbyte; stride, height: integer; x, y: word; val: byte);
var
   i, j, mx, my: integer;
begin
   x += 1;
   y += 1;
   if x + 6 >= stride then mx := stride - 1 else mx := x + 6;
   if y + 6 >= height then my := height - 1 else my := y + 6;

   for i := y to my do
       for j := x to mx do
           p[i * stride + j] := val;
end;



{ visualize_frame
  draw motion vectors and mb types
}
procedure visualize_frame(const fenc: frame_t; var frame: frame_t);

const
  COLORS: array[0..4, 0..1] of byte = (
      ( 80, 160), //I4x4
      (160, 160), //MB_I_16x16
      ( 80,  80), //MB_P_16x16
      (128, 128), //PSkip
       (40, 200)  //I_PCM
  );
  MVOFFSET = 8;

var
  p, pu, pv: pbyte;
  x, y, xy,
  width, height,
  stride, stride_cr: integer;
  mv: motionvec_t;
  draw_square: draw_square_func_t;
  do_mvs, do_mbtypes: boolean;

begin
  p  := frame.plane_dec[0];
  pu := frame.plane_dec[1];
  pv := frame.plane_dec[2];
  stride    := frame.stride;
  stride_cr := frame.stride_c;
  width  := frame.w;
  height := frame.h;
  {
  if (width mod 16 = 0) and (height mod 16 = 0) then
      draw_square := @draw_square_fast
  else  }
      draw_square := @draw_square_slow;

  do_mbtypes := true;
  do_mvs := true;

  for y := 0 to (frame.mbh - 1) do
      for x := 0 to (frame.mbw - 1) do
      begin
          xy := y * frame.mbw + x;

          //draw mv-s
          if do_mvs then
              case fenc.mbs[xy].mbtype of
                  MB_P_16x16, MB_P_SKIP: begin
                      mv := fenc.mbs[xy].mv;
                      mv.x := mv.x div 4;  //scale mv to fpel units
                      mv.y := mv.y div 4;
                      draw_line(p, stride, height,
                          x * 16 + MVOFFSET,        y * 16 + MVOFFSET,
                          x * 16 + MVOFFSET + mv.x, y * 16 + MVOFFSET + mv.y);
                  end;
              end;

          //draw mb_type
          if do_mbtypes then
          begin
              draw_square( pu, stride_cr, height shr 1,
                            x * 8, y * 8,
                            COLORS[ fenc.mbs[xy].mbtype ][0] );
              draw_square( pv, stride_cr, height shr 1,
                            x * 8, y * 8,
                            COLORS[ fenc.mbs[xy].mbtype ][1] );
          end;
      end;
end;


//******************************************************************************

{$R *.lfm}

{ TForm1 }

procedure TForm1.CBSubMEChange(Sender: TObject);
begin
  param.SubpixelMELevel := CBSubME.ItemIndex;
end;

procedure TForm1.CBVisualizeChange(Sender: TObject);
begin
  if enc_state in [ESEncoding, ESPaused] then DrawFrameEncoded;
end;

procedure TForm1.CheckBoxPauseOnKeyChange(Sender: TObject);
begin
  pause_on_key := CheckBoxPauseOnKey.Checked;
end;

procedure TForm1.EditBitrateChange(Sender: TObject);
begin
  param.SetABRRateControl(StrToIntDef(EditBitrate.Text, 500));
end;

procedure TForm1.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  frame_enc_signal := FESStop;
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  ScrollBoxImageFenc.DoubleBuffered := true;

  param := TEncodingParameters.Create;

  input_opened := false;
  output_opened := false;
  encoder_allocated := false;

  pause_on_key := false;
  frame_enc_signal := FESNone;  //or stop
  enc_state := ESStopped;

  screenshot_counter := 0;

  BuildLut;
end;

procedure TForm1.RBQPChange(Sender: TObject);
begin
  {$notice fix this}
  //param.rc.enable := not RBQP.Checked;
  RBQP.Checked := not RBRC2pass.Checked;
end;

procedure TForm1.RBRC2passChange(Sender: TObject);
begin
  {$notice fix this}
  //param.rc.enable := RBRC2pass.Checked;
  RBQP.Checked := not RBRC2pass.Checked;
end;

procedure TForm1.SpinEditKeyIntChange(Sender: TObject);
begin
  param.KeyFrameInterval := SpinEditKeyInt.Value;
end;

procedure TForm1.SpinEditQPChange(Sender: TObject);
begin
  param.QParam := SpinEditQP.Value;
end;

procedure TForm1.SpinEditRefFramesChange(Sender: TObject);
begin
  param.NumReferenceFrames := SpinEditRefFrames.Value;
end;


function TForm1.CreateInputReader(const inputFileName: string): TAbstractFileReader;
var
  ext: string;
begin
  ext := Copy(inputFileName, length(inputFileName) - 3, length(inputFileName));
  if ext = '.avs' then
      result := TAvsReader.Create(inputFileName)
  else if ext = '.y4m' then
      result := TY4MFileReader.Create(inputFileName)
  else
      result := TYuvFileReader.Create(inputFileName, fwidth, fheight);
end;

procedure TForm1.OpenInput;
var
  info: string;
begin
  input := EditInput.Text;
  if not FileExists(input) then begin
      ShowMessage('Input file not found: ' + input);
      exit;
  end;

  infile := CreateInputReader(input);
  fwidth  := infile.FrameWidth;
  fheight := infile.FrameHeight;
  frame_count := infile.FrameCount;
  fps    := infile.FrameRate;

  info := format('input: %dx%d @ %.2f fps, %d frames',
                         [fwidth, fheight, fps, frame_count]);
  StaticTextInputInfo.Caption := info;
  input_opened := true;
end;

procedure TForm1.OpenOutput;
begin
  if not input_opened then exit;
  output := input + '.264';
  AssignFile(fout, output);
  Rewrite   (fout, 1);
  output_opened := true;
end;

procedure TForm1.CreateEncoder;
begin
  param.SetStreamParams(fwidth, fheight, frame_count, fps);
  encoder := TFevh264Encoder.Create(param);
  buffer := getmem(fwidth * fheight * 4);

  encoder_allocated := true;
end;

procedure TForm1.CloseInput;
begin
  if not input_opened then exit;
  infile.Free;
  input_opened := false;
end;

procedure TForm1.CloseOutput;
begin
  if not output_opened then exit;
  CloseFile(fout);
  output_opened := false;
end;

procedure TForm1.FreeEncoder;
begin
  if not encoder_allocated then exit;
  encoder.Free;
  freemem(buffer);
  encoder_allocated := false;
end;

procedure TForm1.EncodeFrame(const i: integer);
var
  progress: string;
  psnr, kbps: single;
  time: integer;
  stream_size: longword;
  ftype: char;
  ssd: int64;
begin
  //get frame
  pic := infile.ReadFrame;
  pic.QParam := SpinEditQP.Value;  //qp adjustment

  //encode
  time := get_msecs();
  encoder.EncodeFrame(pic, buffer, stream_size);
  time := get_msecs() - time;
  time_total += time;

  //store
  BlockWrite(fout, buffer^, stream_size);

  //frame stats
  encoder.GetLastFrameSSD(ssd);
  encoder.GetLastFrame(frame);

  psnr := ssd2psnr(ssd, fwidth * fheight);
  stream_size_total += stream_size;
  kbps := stream_size_total / 1000 * 8 / ((i+1) / fps);
  if frame.ftype = SLICE_I then ftype := 'I' else ftype := 'P';
  progress := format('frame: %6d, type: %s, psnr(dB): %5.2f, size(B): %5d, bitrate(kbps): %7.1f, t(s):%.3f',
                       [i, ftype, psnr, stream_size, kbps, time / 1000]);

  StaticTextProgress.Caption := progress;

  //other
  if CheckBoxPauseOnKey.Checked and (frame.ftype = SLICE_I) then
      frame_enc_signal := FESPause;
end;


{ encode frames in a loop
  -to stop the encoding loop, signal must be set in app.procmsg
  -after receiving a signal or finishing, set proper appstate
  -no state should change until loop exits except encoding flags!
}
procedure TForm1.EncodeFrames;
var
  i: integer;
begin
  if frame_enc_signal = FESEncodeOne then begin
      EncodeFrame(frame_num);
      DrawFrameEncoded;
      frame_num += 1;
      enc_state := ESPaused;
  end
  else if frame_enc_signal = FESEncode then begin

      for i := frame_num to frame_count - 1 do begin
          EncodeFrame(i);
          DrawFrameEncoded;
          frame_num := i + 1;

          //get & process signals, set states accordingly
          Application.ProcessMessages;
          if frame_enc_signal = FESPause then begin
              enc_state := ESPaused;
              StaticTextProgress.Caption :=
                  StaticTextProgress.Caption + ' - encoding paused';
              BStart.Enabled     := true;
              BNextFrame.Enabled := true;
              BPause.Enabled     := false;
              break;
          end;
          if frame_enc_signal = FESStop then begin
              enc_state := ESStopped;
              BStart.Enabled     := true;
              BNextFrame.Enabled := true;
              BPause.Enabled     := false;
              break;
          end;
      end;
  end;
  //no signals to process
  frame_enc_signal := FESNone;
  //finished encoding?
  if frame_num = frame_count then
      enc_state := ESFinished;
end;


procedure TForm1.EncodeInit;
begin
  if not input_opened then
      OpenInput;
  OpenOutput;
  CreateEncoder;
  if not (input_opened and output_opened and encoder_allocated) then begin
      BStart.Enabled := true;
      BPause.Enabled := false;
      BNextFrame.Enabled := true;
      BOpenInput.Enabled := true;
      CloseInput;
      CloseOutput;
      FreeEncoder;
      Showmessage('Failed to start encoding');
      exit;
  end;

  enc_state := ESEncoding;
  stream_size_total := 0;
  time_total := 0;
  frame_num := 0;
  SetImageArea;

  BOpenInput.Enabled := false;
  BStopEncoding.Enabled := true;
end;

procedure TForm1.EncodeFree;
var
  kbps, encoding_fps: single;
begin
  CloseInput;
  CloseOutput;
  FreeEncoder;

  kbps := stream_size_total / 1000 * 8 / (frame_count / fps);
  encoding_fps := frame_num / (time_total / 1000);

  case enc_state of
      ESStopped:
        StaticTextProgress.Caption :=
          'encoding stopped at frame ' + IntToStr(frame_num);
      ESFinished:
        StaticTextProgress.Caption :=
          format('encoding finished, encoded %d frames, %.1f kbps, %.1f fps, %d seconds',
            [frame_num, kbps, encoding_fps, time_total div 1000]);
  else
      StaticTextProgress.Caption := 'Unknown state at EncodeFree. Fix!'
  end;

  BOpenInput.Enabled := true;
  BStart.Enabled     := true;
  BNextFrame.Enabled := true;
  BPause.Enabled     := false;
  BStopEncoding.Enabled := false;

  enc_state := ESStopped;
end;


procedure TForm1.DrawFrameEncoded;
var
  psrc, pdst: pbyte;
  pstride: integer;
  x, y: integer;
  pix: byte;
  tmpframe: frame_t;
  size: integer;

  rawimg: TRawImage;
  rawimg_desc: TRawImageDescription;
  pict: TLazIntfImage;
  row: PRGBAQuad;
  bitmap: TBitmap;
  vis: boolean;
begin
  vis := CBVisualize.Checked;

  //raw 32b RGBA surface
  rawimg_desc.Init_BPP32_B8G8R8A8_BIO_TTB(fwidth, fheight);
  rawimg.Init;
  rawimg.Description := rawimg_desc;
  rawimg.CreateData(false);
  pict := TLazIntfImage.Create(rawimg, true);

  //we will draw on the decoded image planes, so a copy of plane_dec is needed
  if vis then begin
      frame_new(tmpframe, frame.mbw, frame.mbh);
      size := frame.pw * frame.ph;
      move(frame.mem[3]^, tmpframe.mem[3]^, 4 * size + size div 2);
      visualize_frame(frame, tmpframe);
  end else
      tmpframe := frame;

  if CBDisplayLuma.Checked then begin
      //copy luma only
      psrc    := tmpframe.plane_dec[0];
      pstride := tmpframe.stride;
      for y := 0 to fheight - 1 do begin
          row := PRGBAQuad( pict.GetDataLineStart(y) );
          for x := 0 to fwidth - 1 do begin
              pix := psrc[x];
              row[x].Red   := pix;
              row[x].Green := pix;
              row[x].Blue  := pix;
              row[x].Alpha := 255;
          end;
          psrc += pstride;
      end;
  end else begin
      //colorspace conversion
      cspc_yv12_to_rgba32(pict, tmpframe);
  end;

  if vis then frame_free(tmpframe);

  //display
  bitmap := TBitmap.Create;
  bitmap.LoadFromIntfImage(pict);
  ImageFenc.Canvas.Draw(0, 0, bitmap);
  ImageFenc.Canvas.TextOut(0, 0, IntToStr(frame.qp));

  //free
  pict.Free;
  bitmap.Free;
  rawimg.ReleaseData;
end;


procedure TForm1.SetImageArea;
begin
  ImageFenc.Width  := fwidth;
  ImageFenc.Height := fheight;
end;


procedure TForm1.BOpenInputClick(Sender: TObject);
begin
  if OpenDialogInput.Execute then begin
      EditInput.Text := OpenDialogInput.FileName;
  end;
  OpenInput;
end;

procedure TForm1.BNextFrameClick(Sender: TObject);
begin
  BStart.Enabled     := true;
  BPause.Enabled     := false;
  BNextFrame.Enabled := true;
  if enc_state = ESStopped then
      EncodeInit;
  frame_enc_signal := FESEncodeOne;
  EncodeFrames;
  if enc_state in [ESStopped, ESFinished] then
      EncodeFree;
end;

procedure TForm1.BStartClick(Sender: TObject);
begin
  BStart.Enabled     := false;
  BPause.Enabled     := true;
  BNextFrame.Enabled := false;
  if enc_state = ESStopped then
      EncodeInit;
  frame_enc_signal := FESEncode;
  EncodeFrames;
  if enc_state in [ESStopped, ESFinished] then
      EncodeFree;
end;

procedure TForm1.BPauseClick(Sender: TObject);
begin
  frame_enc_signal := FESPause;
  enc_state := ESPaused;
  BStart.Enabled     := true;
  BNextFrame.Enabled := true;
end;

procedure TForm1.BStopEncodingClick(Sender: TObject);
begin
  case enc_state of
      //exit from loop
      ESEncoding: frame_enc_signal := FESStop;
      //just close the encode from here
      ESPaused: begin
          enc_state := ESStopped;
          EncodeFree;
          BStart.Enabled     := true;
          BNextFrame.Enabled := true;
          BPause.Enabled     := false;
      end;
  end;
end;

procedure TForm1.BSaveScreenshotClick(Sender: TObject);
var
  s: string;
begin
  s := format('screenshot%.3d.png', [screenshot_counter]);
  ImageFenc.Picture.SaveToFile(s);
  screenshot_counter += 1;
end;

procedure TForm1.CBAnalyseChange(Sender: TObject);
begin
  param.AnalysisLevel := CBAnalyse.ItemIndex;
end;

procedure TForm1.CBLoopFilterChange(Sender:TObject);
begin
  param.LoopFilterEnabled := CBLoopFilter.Checked;
end;

procedure TForm1.CBNoChromaChange(Sender: TObject);
begin
  param.IgnoreChroma := CBNoChroma.Checked;
end;

procedure TForm1.CBStatsChange(Sender: TObject);
begin
  param.WriteStatsFile := CBStats.Checked;
end;

end.

