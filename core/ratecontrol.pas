(*******************************************************************************
ratecontrol.pas
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

unit ratecontrol;
{$mode objfpc}{$H+}
{$define RC_CONSOLE_WRITE}

interface

uses
  SysUtils,
  common, util, fgl;

type
TBufferState = (bsUnderflow, bsOverflow, bsStable);

const
TBufferStateName: array[bsUnderflow..bsStable] of string = ('under', 'over', 'stable');

type

TRcFrame = record
    bitsize: integer;
    tex_bits: integer;
    itex, ptex: integer;
    misc_bits: integer;
    frame_type: byte;
    qp: byte;
    qp_init: byte;
    mb_i, mb_p, mb_skip: integer;
end;
PRcFrame = ^TRcFrame;

{ TRcGop }

TRcGop = class
  private
    procedure AdjustByFrameReferences;
    procedure AdjustByFrameRelativeSize(const avg_bitsize: integer);
    procedure AdjustByGopRelativeSize(const avg_bitsize: integer);
    procedure GopQPBlur;
  public
    length: integer;
    I_only: boolean;
    frames: array of PRcFrame;

    destructor Free;
    procedure AdjustRelativeQPs(const avg_bitsize: integer; const default_qp: integer);
    procedure ShiftQPs(diff: integer);
end;

TRcGopList = specialize TFPGList<TRcGop>;

TRateControlMode = (tRcConstQP = 0, tRc2passAvg = 1); //0 - cqp, 1 - 2nd pass avg. bitrate

{ TRatecontrol }

TRatecontrol = class
  private
    mode: TRateControlMode;
    qp_const: byte;
    intra_bonus: byte;
    nframes: integer;
    frames: array of TRcFrame;
    gop_list: TRcGopList;
    desired_bitrate: integer;  //kbps
    fps: single;
    encoded_qp_avg: single;
    rate_mult: single;
    stream_bits_estimated,
    stream_bits_real: int64;
    last_buffer_check,
    last_diff: integer;
    avg_target_framesize: integer;
    bit_reserve: integer;
    qp_comp: integer;
    buffer_state: TBufferState;
    last_buffer_change: integer;
    bit_reserve_reduce_from: integer;
    ssd: int64;

    procedure CreateGOPs();
    procedure ReadStatsFile(const fname: string);
    procedure Analyse;
    procedure SetBitReserveReductionPoint;
  public
    constructor Create;
    destructor Free;
    procedure SetConstQP(const ConstQP: byte);
    procedure Set2pass
      (const TargetBitrate, FrameCount: integer; const FramesPS: single; const Statsfile: string);
    function  GetQP (const FrameNum: integer; const FrameType: byte): byte;
    function  GetFrameType (const FrameNum: integer): byte;
    procedure Update(const FrameNum: integer; const FrameBits: integer; var f: frame_t);
end;


implementation

//estimate new frame size by 1st pass stats
function RecalculateFrameSize(var frame: TRcFrame): integer;
var
  diff: integer;
  bits_ptex, bits_itex, bits_misc: integer;
  mult_ptex, mult_itex, mult_misc: integer;
begin
  result := frame.bitsize;
  diff := frame.qp_init - frame.qp;
  if diff = 0 then
      exit;
  if frame.bitsize < 256 then
      exit;

  if frame.frame_type = SLICE_I then begin
      mult_itex := 6;
      if (frame.itex / frame.mb_i) < 10 then
          mult_itex := 12;

      if diff > 0 then begin
          //lower qp -> increase bitrate
          bits_itex := trunc( (diff / mult_itex) * frame.itex ) + frame.itex;
      end else begin
          //higher qp -> decrease bitrate
          diff := -diff;
          bits_itex := trunc( 1 / (1 + diff / mult_itex) * frame.itex );
      end;
      bits_ptex := 0;
      bits_misc := frame.misc_bits;
  end else begin
      mult_ptex := 3;
      mult_itex := 6;
      mult_misc := 24;
      if frame.mb_p > 0 then begin
          if frame.ptex / frame.mb_p > 100 then
              mult_ptex += 1;
          if frame.ptex / frame.mb_p < 25 then
              mult_ptex -= 1;
      end;
      if (frame.mb_i > 0) and (frame.itex / frame.mb_i < 10) then
                mult_itex := 3;

      if diff > 0 then begin
          bits_ptex := trunc( (diff / mult_ptex) * frame.ptex ) + frame.ptex;
          bits_itex := trunc( (diff / mult_itex) * frame.itex ) + frame.itex;
          bits_misc := trunc( (diff / mult_misc) * frame.misc_bits ) + frame.misc_bits;
      end else begin
          diff := -diff;
          bits_ptex := trunc( 1 / (1 + diff / mult_ptex) * frame.ptex );
          bits_itex := trunc( 1 / (1 + diff / mult_itex) * frame.itex );
          bits_misc := trunc( 1 / (1 + diff / mult_misc) * frame.misc_bits );
      end;
  end;
  result := bits_itex + bits_ptex + bits_misc;
  //writeln(stderr, frame.qp_init:3, frame.qp:3, diff:3, frame.bitsize:20, frame.tex_bits:20, result: 20);
  frame.bitsize := result;
end;


{ TRcGop }

procedure TRcGop.AdjustRelativeQPs(const avg_bitsize: integer; const default_qp: integer);
var
  i: integer;
begin
  //nonreferenced I frame
  if length = 1 then begin
      frames[0]^.qp := default_qp;
      exit;
  end;

  if I_only then begin
      for i := 0 to length - 1 do
          frames[i]^.qp := default_qp;
  end
  else begin
      AdjustByGopRelativeSize(avg_bitsize);
      AdjustByFrameRelativeSize(avg_bitsize);
      AdjustByFrameReferences;
      ////GopQPBlur;
  end;

  //nonreferenced last frame penalty
  frames[length - 1]^.qp += 1;
end;


procedure TRcGop.AdjustByGopRelativeSize(const avg_bitsize: integer);
var
  i: integer;
  bitsize, avg_gop_frame_size: integer;
  qp_bonus: integer;
begin
  bitsize := 0;
  for i := 1 to length - 1 do
      bitsize += frames[i]^.bitsize;
  avg_gop_frame_size := bitsize div (length - 1);

  qp_bonus := 0;
  if avg_gop_frame_size < avg_bitsize / 2 then
      qp_bonus := -1;
  if avg_gop_frame_size > avg_bitsize / 2 then
      qp_bonus := 1;

  for i := 1 to length - 1 do
      frames[i]^.qp += qp_bonus;
end;


//improve/reduce frames far below/above avg. frame size
procedure TRcGop.AdjustByFrameRelativeSize(const avg_bitsize: integer);
const
  MAX_QP_DELTA = 5;
var
  i: integer;
  bitsize: integer;
  qp, qp_bonus: integer;
begin
  //I frame - boost only
  bitsize := frames[0]^.bitsize;
  qp := frames[0]^.qp;
  if bitsize < avg_bitsize / 2 then begin
      qp_bonus := avg_bitsize div bitsize * 2;
      qp_bonus := min(qp_bonus, MAX_QP_DELTA);
      frames[0]^.qp := clip3 (10, qp - qp_bonus, 51);
  end;

  //P frames
  for i := 1 to length - 1 do begin
      bitsize := frames[ i] ^.bitsize;
      qp := frames[ i] ^.qp;
      if bitsize < avg_bitsize / 2 then begin
          qp_bonus := avg_bitsize div bitsize;
          qp_bonus := min(qp_bonus, MAX_QP_DELTA);
          frames[ i] ^.qp := clip3 (10, qp - qp_bonus, 51);
      end;

      if bitsize > avg_bitsize * 2 then begin
          qp_bonus := bitsize div avg_bitsize;
          qp_bonus := min(qp_bonus, MAX_QP_DELTA);
          frames[ i] ^.qp := clip3 (10, qp + qp_bonus, 51);
      end;
  end;
end;

//improve frames if followed by frame with mostly skip MBs
procedure TRcGop.AdjustByFrameReferences;
var
  i, k: integer;
  mb_count: integer;
  qp_bonus: integer;
  qp_bonusf: single;
begin
  mb_count := frames[0]^.mb_i;
  for i := 0 to length - 2 do begin
      k := i + 1;
      qp_bonusf := 0;
      while (k <= length - 1) and (frames[k]^.mb_skip > mb_count div 8 * 7) do begin
          qp_bonusf += 0.5;
          k += 1;
      end;
      qp_bonus := min(trunc(qp_bonusf), 6);
      frames[i] ^.qp := clip3 (10, integer(frames[i]^.qp) - qp_bonus, 51);
  end;
end;


procedure TRcGop.GopQPBlur;
var
  i, j: integer;
  tmp: array of byte;
  qp: integer;
begin
  SetLength(tmp, length + 4);
  tmp[0] := frames[1]^.qp;  //don't let I frame influence the rest
  for i := 1 to length - 1 do
      tmp[i] := frames[i]^.qp;
  for i := length to length + 1 do
      tmp[i] := frames[length - 1]^.qp;

  for i := 2 to length - 1 do begin
      qp := 0;
      for j := i - 2 to i + 2 do
          qp += tmp[j];
      qp := qp div 5;
      frames[i]^.qp := qp;
  end;
  tmp := nil;
end;


destructor TRcGop.Free;
begin
  frames := nil;
end;


procedure TRcGop.ShiftQPs(diff: integer);
var
  i: integer;
begin
  for i := 0 to length - 1 do
      frames[i]^.qp := clip3 (0, frames[i]^.qp + diff, 51);
end;


{ TRatecontrol }

procedure TRatecontrol.ReadStatsFile(const fname: string);
var
  f: TextFile;
  s: string;
  i: integer;
  fnum: integer;
  qpa: double;
  ftype, bogus: char;
  frame: TRcFrame;
begin
  AssignFile(f, fname);
  Reset(f);
  readln(f, s); //encoder params
  for i := 0 to nframes - 1 do begin
      readln(f, s);
      if EOF(f) or (s[1] = 's'{stream stats}) then begin
          writeln(stderr, 'wrong statsfile, too few frames: ', i, '/', nframes);
          halt;
      end;
      SScanf(s, '%d%c%c qp: %d (%f) size: %d  itex: %d  ptex: %d  other: %d  i:%d p:%d skip: %d',
        [@fnum, @bogus, @ftype,
         @frame.qp, @qpa, @frame.bitsize,
         @frame.itex, @frame.ptex, @frame.misc_bits,
         @frame.mb_i, @frame.mb_p, @frame.mb_skip]);

      frame.qp_init := frame.qp;
      frame.tex_bits := frame.itex + frame.ptex;
      frame.frame_type := SLICE_I;
      if ftype = 'P' then
          frame.frame_type := SLICE_P;
      frames[i] := frame;
      //writeln(stderr, frames[i].bitsize:20, frames[i].tex_bits:20, frames[i].misc_bits:20, frames[i].mb_skip:20);
  end;
  CloseFile(f);
end;


procedure TRatecontrol.CreateGOPs;
var
  i, k: integer;
  gop: TRcGop;
  gop_len: integer;
begin
  i := 0;
  while i < nframes - 1 do begin
      gop := TRcGop.Create;

      gop_len := 0;
      repeat
          gop_len += 1;
      until (i + gop_len >= nframes) or (frames[i + gop_len].frame_type = SLICE_I);
      //in successive I frames case, insert all I frames in one GOP
      if gop_len = 1 then begin
          repeat
              gop_len += 1;
          until (i + gop_len >= nframes) or (frames[i + gop_len].frame_type <> SLICE_I);
          //last I belongs to next GOP
          if i + gop_len < nframes then
              gop_len -= 1;
          gop.I_only := true;
      end;

      gop.length := gop_len;
      SetLength(gop.frames, gop.length);
      for k := 0 to gop.length - 1 do
      gop.frames[k] := @frames[i + k];
      gop_list.Add(gop);

      i += gop_len;
  end;
  //for i := 0 to gop_list.Count - 1 do writeln(stderr, 'gop ', i, ' length: ', gop_list[i].length);
end;


procedure TRatecontrol.Analyse;
var
  i: integer;
  stream_size_total: int64;
  kbps: single;
  avg_size: integer;
  diff: integer;
  qp_avg: single;
  qp_init: integer;
  gop: TRcGop;
  reserve_frames: integer;
begin
  //calculate average frame size & average QP from stored stats
  qp_avg := 0;
  stream_size_total := 0;
  for i := 0 to nframes - 1 do begin
      stream_size_total += frames[i].bitsize;
      qp_avg += frames[i].qp;
  end;
  qp_avg := qp_avg / nframes;
  avg_size := stream_size_total div nframes;
  kbps := stream_size_total / 1000 / (nframes / fps);
  writeln(stderr, 'rc: stat avg. qp: ', qp_avg:5:2, ' kbps: ', kbps:7:1);
  writeln(stderr, 'rc: avg. frame size: ', avg_size:2);

  //redistribute QPs
  CreateGOPs();
  for gop in gop_list do
      gop.AdjustRelativeQPs(avg_size, round(qp_avg));

  //predict new frame sizes according to modified QPs
  qp_avg := 0;
  stream_size_total := 0;
  for i := 0 to nframes - 1 do begin
      stream_size_total += RecalculateFrameSize(frames[i]);
      qp_avg += frames[i].qp;
  end;
  qp_avg := qp_avg / nframes;

  //find QP that would fit the desired filesize
  kbps := stream_size_total / 1000 / (nframes / fps);
  rate_mult := desired_bitrate / kbps;
  if rate_mult > 1 then begin
      qp_init := trunc(qp_avg - (rate_mult - 1) * 5);
  end else begin
      qp_init := trunc(qp_avg + (1 / rate_mult - 1) * 5);
  end;
  qp_init := clip3 (0, qp_init, 51);
  diff := round( qp_init - qp_avg );

  //shift all QPS and predict new frame sizes.
  //Calculate rate compensation, because the sizes won't precisely lead to desired stream size:
  //we would need a perfect frame size predictor and fractional per-frame QPs for that
  for gop in gop_list do
      gop.ShiftQPs(diff);
  stream_size_total := 0;
  for i := 0 to nframes - 1 do
      stream_size_total += RecalculateFrameSize(frames[i]);
  kbps := stream_size_total / 1000 / (nframes / fps);
  rate_mult := desired_bitrate / kbps;

  //bit_reserve for frame size fluctuations
  avg_target_framesize := trunc( desired_bitrate * 1000 * (nframes / fps) / nframes );
  reserve_frames := min( nframes div 100, 3 );
  bit_reserve := trunc( avg_target_framesize * reserve_frames );
  SetBitReserveReductionPoint;

{$ifdef RC_CONSOLE_WRITE}
  writeln(stderr, 'rc: adjusted qp: ', qp_avg:5:2, ' kbps: ', kbps:7:1);
  writeln(stderr, 'rc: target avg. frame size: ', avg_target_framesize:2);
  writeln(stderr, 'rc: rate_mult: ', rate_mult:5:3);
  writeln(stderr, 'rc: initial qp: ', qp_init:2);
  writeln(stderr, 'rc: bit reserve: ', bit_reserve:2);
{$endif}
end;


//Try to guess a frame at which we should start reducing bit_reserve to fit the desired stream size
procedure TRatecontrol.SetBitReserveReductionPoint;
var
  remaining_size: integer;
  sum_bits: integer;
  i: integer;
begin
  if bit_reserve = 0 then begin
      bit_reserve_reduce_from := nframes;
      exit;
  end;
  remaining_size := bit_reserve * 30;
  if remaining_size > nframes * avg_target_framesize then
      remaining_size := (nframes - 1) * avg_target_framesize;

  sum_bits := 0;
  i := nframes - 1;
  while (sum_bits < remaining_size) and (i > 0) do begin
      sum_bits += trunc(frames[i].bitsize * rate_mult);
      i -= 1;
  end;
  bit_reserve_reduce_from := i;
  //writeln(stderr, 'bit_reserve_reduce_from: ', bit_reserve_reduce_from);
end;


constructor TRatecontrol.Create;
begin
  gop_list := TRcGopList.Create;
  frames := nil;
  qp_const := 22;
  fps := 25;
  intra_bonus := 2;
  desired_bitrate := 2000;
  stream_bits_real := 0;
  stream_bits_estimated := 0;

  last_buffer_check := 0;
  last_diff := 0;
  qp_comp := 0;
  buffer_state := bsStable;
  ssd := 0;
end;

destructor TRatecontrol.Free;
var
  gop: TRcGop;
begin
  frames := nil;
  if mode = tRc2passAvg then begin
{$ifdef RC_CONSOLE_WRITE}
      writeln(stderr, 'rc: avg.qp: ', encoded_qp_avg / nframes:4:2);
      writeln(stderr, 'stddev: ', sqrt(ssd / nframes):10:2);
{$endif}
  end;
  for gop in gop_list do
      gop.Free;
  gop_list.Free;
end;

procedure TRatecontrol.SetConstQP(const ConstQP: byte);
begin
  qp_const := clip3(0, ConstQP, 51);
  mode := tRcConstQP;
end;

procedure TRatecontrol.Set2pass(const TargetBitrate, FrameCount: integer; const FramesPS: single; const Statsfile: string);
begin
  dsp.FpuReset;
  desired_bitrate := TargetBitrate;
  nframes := FrameCount;
  fps := FramesPS;
  mode := tRc2passAvg;
  //read stats
  SetLength(frames, nframes);
  ReadStatsFile(Statsfile);
  Analyse;
end;

function TRatecontrol.GetQP(const FrameNum: integer; const FrameType: byte): byte;
begin
  result := qp_const;
  case mode of
    tRcConstQP: begin
        if FrameType = SLICE_I then
            result := max(result - intra_bonus, 0);
    end;
    tRc2passAvg: begin
        result := clip3 (0, frames[FrameNum].qp + qp_comp, 51);
    end;
  end;

  dsp.FpuReset;
  encoded_qp_avg += result;
end;

function TRatecontrol.GetFrameType(const FrameNum: integer): byte;
begin
  result := SLICE_P;
  if mode = tRc2passAvg then
      result := frames[FrameNum].frame_type;
end;


procedure TRatecontrol.Update(const FrameNum: integer; const FrameBits: integer; var f: frame_t);
const
  STATECHECK_INTERVAL = 10;
  REACTION_DELAY = 30;
var
  new_diff: integer;
  estimated_framebits: integer;
  bits_delta: int64;
begin
  if mode = tRcConstQP then
      exit;
  dsp.FpuReset;

  estimated_framebits := frames[FrameNum].bitsize;
  stream_bits_estimated += trunc( estimated_framebits * rate_mult );
  stream_bits_real += FrameBits;
  new_diff := stream_bits_real - stream_bits_estimated;
  //writeln(stderr, framenum:5, ' diff: ', new_diff:20, ' qpcomp: ', qp_comp);

  bits_delta := estimated_framebits - FrameBits;
  ssd += bits_delta * bits_delta;
  //if (abs(bits_delta) > FrameBits) then
  //    writeln(stderr, framenum:5, ' est: ', estimated_framebits:20, ' real: ', FrameBits: 20);
  f.estimated_framebits := estimated_framebits;
  f.qp_adj := qp_comp;

  //reduce bitreserve towards stream end
  if (FrameNum = bit_reserve_reduce_from) and (bit_reserve >= avg_target_framesize) then begin
      bit_reserve -= avg_target_framesize;
      case buffer_state of
          bsUnderflow: qp_comp -= 1;
          bsOverflow: qp_comp += 1;
      end;
      SetBitReserveReductionPoint();
  end;

  if FrameNum - last_buffer_check < STATECHECK_INTERVAL then
      exit;

  //writeln(stderr, 'buffer state: ', TBufferStateName[buffer_state]);
  last_buffer_check := FrameNum;

  //check changes in stream
  case buffer_state of

      //check if over/underflow and treat
      bsStable: begin
         //underflow
          if stream_bits_real < stream_bits_estimated - bit_reserve then begin
              buffer_state := bsUnderflow;
              qp_comp -= 1;
              last_buffer_change := FrameNum;
              //writeln(stderr, framenum:5, ' underflow');
          end;
          if stream_bits_real > stream_bits_estimated + bit_reserve then begin
              buffer_state := bsOverflow;
              qp_comp += 1;
              last_buffer_change := FrameNum;
              //writeln(stderr, framenum:5, ' overflow');
          end;
      end;

      //check underflow state
      bsUnderflow: begin
          if new_diff > last_diff then begin
          //recovering - do nothing
          end else begin
          //needs stronger treatment
              if FrameNum - last_buffer_change >= REACTION_DELAY then begin
                  qp_comp -= 1;
                  last_buffer_change := FrameNum;
              end;
              //writeln(stderr, framenum:5, ' still underflowing!');
          end;
          //no more underflow, stabilize
          if stream_bits_real + bit_reserve > stream_bits_estimated then begin
              buffer_state := bsStable;
              qp_comp += 1;
          end;
      end;

      //check underflow state
      bsOverflow: begin
          if new_diff < last_diff then begin
          //recovering - do nothing
          end else begin
          //needs stronger treatment
              if FrameNum - last_buffer_change >= REACTION_DELAY then begin
                  qp_comp += 1;
                  last_buffer_change := FrameNum;
              end;
              //writeln(stderr, framenum:5, ' still overflowing!');
          end;
          //no more overflow
          if stream_bits_real < stream_bits_estimated + bit_reserve then begin
              buffer_state := bsStable;
              qp_comp -= 1;
          end;
      end;
  end;

  last_diff := new_diff;
end;

end.

