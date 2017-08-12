(*******************************************************************************
stats.pas
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
unit stats;

{$mode objfpc}{$H+}

interface

type

  { TFrameStats }

  TFrameStats = class
    public
      pred: array[0..8] of int64;
      pred16: array[0..3] of int64;
      pred_8x8_chroma: array[0..3] of int64;
      ref: array[0..15] of int64;
      ptex_bits,
      itex_bits,
      mb_skip_count,
      mb_i4_count,
      mb_i16_count,
      mb_p_count: int64;
      size_bytes: int64;
      ssd: array[0..2] of int64;

      constructor Create;
      procedure Clear; virtual;
      procedure Add(a: TFrameStats);
      procedure WriteMBInfo         (var f: TextFile);
      procedure WritePredictionInfo (var f: TextFile);
      procedure WriteReferenceInfo  (var f: TextFile; const refcount: integer);
  end;

  { TStreamStats }

  TStreamStats = class(TFrameStats)
    public
      i_count,
      p_count: int64;

      procedure Clear; override;
      procedure WriteStreamInfo(var f: TextFile);
  end;

(*******************************************************************************
*******************************************************************************)
implementation

const
  I4x4_PRED_NAMES: array[0..8] of string[3] = ('v', 'h', 'dc', 'ddl', 'ddr', 'vr', 'hd', 'vl', 'hu');
  I16x16_PRED_NAMES:  array[0..3] of string[5] = ('v', 'h', 'dc', 'plane');
  ICHROMA_PRED_NAMES: array[0..3] of string[5] = ('dc', 'h', 'v', 'plane');

{ TStreamStats }

procedure TStreamStats.Clear;
begin
  inherited Clear;
  i_count := 0;
  p_count := 0;
end;

procedure TStreamStats.WriteStreamInfo(var f: TextFile);
begin
  writeln( f, 'stream size: ', size_bytes:10, ' B  (', size_bytes /1024/1024:6:2, ' MB)' );
  writeln( f, 'I-frames: ', i_count );
  writeln( f, 'P-frames: ', p_count );
end;

{ TFrameStats }

constructor TFrameStats.Create;
begin
  Clear;
end;

procedure TFrameStats.Clear;
begin
  Fillbyte(pred,   sizeof(pred), 0);
  Fillbyte(pred16, sizeof(pred16), 0);
  Fillbyte(pred_8x8_chroma, sizeof(pred_8x8_chroma), 0);
  Fillbyte(ref,    sizeof(ref), 0);
  Fillbyte(ssd,    sizeof(ssd), 0);
  ptex_bits := 0;
  itex_bits := 0;
  mb_skip_count := 0;
  mb_i4_count   := 0;
  mb_i16_count  := 0;
  mb_p_count    := 0;
  size_bytes := 0;
end;

procedure TFrameStats.Add(a: TFrameStats);
var
  i: integer;
begin
  itex_bits     += a.itex_bits;
  ptex_bits     += a.ptex_bits;
  mb_i4_count   += a.mb_i4_count;
  mb_i16_count  += a.mb_i16_count;
  mb_p_count    += a.mb_p_count;
  mb_skip_count += a.mb_skip_count;
  size_bytes    += a.size_bytes;
  for i := 0 to 8 do
      pred[i]   += a.pred[i];
  for i := 0 to 3 do
      pred16[i] += a.pred16[i];
  for i := 0 to 3 do
      pred_8x8_chroma[i] += a.pred_8x8_chroma[i];
  for i := 0 to 15 do
      ref[i] += a.ref[i];
  for i := 0 to 2 do
      ssd[i] += a.ssd[i];
end;

procedure TFrameStats.WriteMBInfo(var f: TextFile);
begin
  writeln( f, 'mb counts:' );
  writeln( f, '  I4x4:  ', mb_i4_count:10);
  writeln( f, '  I16x16:', mb_i16_count:10);
  writeln( f, '  P_L0:  ', mb_p_count:10);
  writeln( f, '  skip:  ', mb_skip_count:10);
  writeln( f, 'residual bits:' );
  writeln( f, '  itex:    ', itex_bits:10 );
  writeln( f, '  ptex:    ', ptex_bits:10 );
  writeln( f, 'other bits:', size_bytes * 8 - (itex_bits + ptex_bits):10 );
end;

procedure TFrameStats.WritePredictionInfo(var f: TextFile);
var
  i: integer;
  blk_n: int64;
begin
  write(f, 'I4x4 pred:   ');
  blk_n := 16 * mb_i4_count;
  if blk_n > 0 then
      for i := 0 to length(pred) - 1 do
          write(f, I4x4_PRED_NAMES[i], ': ', pred[i] / (blk_n / 100) :3:1, '% ');
  writeln(f);
  write(f, 'I16x16 pred: ');
  blk_n := mb_i16_count;
  if blk_n > 0 then
      for i := 0 to length(pred16) - 1 do
          write(f, I16x16_PRED_NAMES[i], ': ', pred16[i] / (blk_n / 100) :3:1, '% ');
  writeln(f);
  write(f, 'chroma pred: ');
  blk_n := mb_i4_count + mb_i16_count;
  if blk_n > 0 then
      for i := 0 to length(pred_8x8_chroma) - 1 do
          write(f, ICHROMA_PRED_NAMES[i], ': ', pred_8x8_chroma[i] / (blk_n / 100) :3:1, '% ');
  writeln(f);
end;

procedure TFrameStats.WriteReferenceInfo(var f: TextFile; const refcount: integer);
var
  mbp_count: integer;
  i: integer;
begin
  if refcount > 1 then begin
      mbp_count := mb_p_count + mb_skip_count;
      write(f, 'L0 ref: ');
      for i := 0 to refcount - 1 do begin
          write(f, ref[i] / (mbp_count / 100):3:1, '% ');
      end;
      writeln(f);
  end;
end;

end.

