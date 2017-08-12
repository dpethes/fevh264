(*******************************************************************************
loopfilter.pas
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
unit loopfilter;
{$mode objfpc}{$H+}

interface

uses
  common, util, classes, sysutils, syncobjs;

type
  IDeblocker = class
      procedure MBRowFinished; virtual; abstract;
      procedure FrameFinished; virtual; abstract;
  end;

function GetNewDeblocker(const frame: frame_t; const constant_qp, threading_enabled: boolean): IDeblocker;
procedure CalculateBStrength (const mb: macroblock_p);

(*******************************************************************************
*******************************************************************************)
implementation

type

  { TDeblockThread }
  TDeblockThread = class(TThread)
    private
      _encoded_mb_rows: integer;
      _encoded_mb_rows_lock: TCriticalSection;
      _row_processed_event: TSimpleEvent;
      _abort: boolean;
      _abort_lock: TCriticalSection;

      function GetAbort: boolean;
      procedure SetEncodedMBRows(AValue: integer);
      function GetEncodedMBRows(): integer;

    public
      frame: frame_p;
      cqp: boolean;

      property EncodedMBRows: integer read GetEncodedMBRows write SetEncodedMBRows;
      property Abort: boolean read GetAbort;

      constructor Create;
      destructor Free;

      procedure Execute; override;
      procedure IncreaseEncodedMBRows;
      procedure AbortProcessing;
  end;

  { TThreadedDeblocker
    Deblocks in paralell with encoding; running a few macroblock rows behind the encoding thread
  }
  TThreadedDeblocker = class(IDeblocker)
    private
      dthread: TDeblockThread;
      scheduled_mbrows: integer;
      f: frame_p;
      _is_frame_finished: boolean;
    public
      constructor Create(const frame: frame_t; const cqp: boolean = true);
      destructor Destroy; override;
      procedure MBRowFinished; override;
      procedure FrameFinished; override;
  end;

  { TSimpleDeblocker
    Deblocks after the whole frame is encoded
  }
  TSimpleDeblocker = class(IDeblocker)
    private
      f: frame_p;
      scheduled_mbrows: integer;
      _cqp: boolean;
    public
      constructor Create(const frame: frame_t; const cqp: boolean = true);
      procedure FrameFinished; override;
      procedure MBRowFinished; override;
  end;


function GetNewDeblocker(const frame: frame_t; const constant_qp, threading_enabled: boolean): IDeblocker;
begin
    if threading_enabled then
        result := TThreadedDeblocker.Create(frame, constant_qp)
    else
        result := TSimpleDeblocker.Create(frame, constant_qp);
end;

const
//Table 8-14 – Derivation of indexA and indexB from offset dependent threshold variables α and β
TAB_ALPHA: array[0..51] of byte = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,4,5,6,7,8,9,10,12,13,
           15,17,20,22,25,28,32,36,40,45,50,56,63,71,80,90,101,113,127,144,162,182,203,226,255,255);
TAB_BETA: array[0..51] of byte = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,2,2,3,3,3,3,4,4,4,
          6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15,16,16,17,17,18,18);

//Table 8-15 – Value of filter clipping variable tC0 as a function of indexA and bS
TAB_TC0: array[1..3, 0..51] of byte = (
  (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,
   1,1,1,1,1,1,1,2,2,2,2,3,3,3,4,4,4,5,6,6,7,8,9,10,11,13),
  (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,
   1,1,1,1,1,2,2,2,2,3,3,3,4,4,5,5,6,7,8,8,10,11,12,13,15,17),
  (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,
   1,2,2,2,2,3,3,3,4,4,4,5,6,6,7,8,9,10,11,13,14,16,18,20,23,25)
);

XY2IDX: array[0..3, 0..3] of byte = (
  ( 0,  2,  8, 10),
  ( 1,  3,  9, 11),
  ( 4,  6, 12, 14),
  ( 5,  7, 13, 15)
);

function clip(i: integer): byte; inline;
begin
  if i > 255 then i := 255
  else if i < 0 then i := 0;
  result := byte(i);
end;


{ 8.7.2.1 Derivation process for the luma content dependent boundary filtering strength
mixedModeEdgeFlag = 0 (prog)
}
procedure CalculateBStrength (const mb: macroblock_p);

  function coef_test_mbedge(const a, b: macroblock_p; na, nb: integer): integer;
  begin
    if a^.nz_coef_cnt[na] + b^.nz_coef_cnt[nb] > 0 then  //p/q non-zero coeffs
        result := 2
    else if (a^.ref <> b^.ref)        //different ref, mv delta >= 4, diff. partitions
        or (( abs(a^.mv.x - b^.mv.x) >= 4 ) or ( abs(a^.mv.y - b^.mv.y) >= 4 ))
    then
       result := 1
    else
       result := 0;
  end;

  function coef_test(const a: macroblock_p; na, nb: integer): integer; inline;
  begin
    if a^.nz_coef_cnt[na] + a^.nz_coef_cnt[nb] > 0 then result := 2
    else result := 0;
  end;

const
  intra_bs_vert: TBSarray = (
    (4, 4, 4, 4),
    (3, 3, 3, 3),
    (3, 3, 3, 3),
    (3, 3, 3, 3)
  );
  intra_bs_horiz: TBSarray = (
    (4, 3, 3, 3),
    (4, 3, 3, 3),
    (4, 3, 3, 3),
    (4, 3, 3, 3)
  );

var
  i, j: integer;
  mba, mbb: macroblock_p;

begin
  if is_intra(mb^.mbtype) then begin
      mb^.bS_vertical := intra_bs_vert;
      mb^.bS_horizontal := intra_bs_horiz;
      exit;
  end;

  //internal edges
  if (mb^.mbtype = MB_P_SKIP) or (mb^.cbp = 0) then begin
      FillQWord(mb^.bS_vertical, 2, 0);
      FillQWord(mb^.bS_horizontal, 2, 0);
  end else begin
      for i := 1 to 3 do
          for j := 0 to 3 do
              mb^.bS_vertical[i, j] := coef_test(mb, XY2IDX[i, j], XY2IDX[i-1, j]);
      for i := 0 to 3 do
          for j := 1 to 3 do
              mb^.bS_horizontal[i, j] := coef_test(mb, XY2IDX[i, j], XY2IDX[i, j-1]);
  end;


  //vertical edges - left edge
  if mb^.x > 0 then begin
      mba := mb^.mba;
      if is_intra(mba^.mbtype) then begin
          for i := 0 to 3 do
              mb^.bS_vertical[0, i] := 4;  //edge with intra
      end else begin
          mb^.bS_vertical[0, 0] := coef_test_mbedge(mb, mba, 0,  5);
          mb^.bS_vertical[0, 1] := coef_test_mbedge(mb, mba, 2,  7);
          mb^.bS_vertical[0, 2] := coef_test_mbedge(mb, mba, 8, 13);
          mb^.bS_vertical[0, 3] := coef_test_mbedge(mb, mba,10, 15);
      end;
  end;

  //horizontal edges - top edge
  if mb^.y > 0 then begin
      mbb := mb^.mbb;
      if is_intra(mbb^.mbtype) then begin
          for i := 0 to 3 do
              mb^.bS_horizontal[i, 0] := 4;
      end else begin
          mb^.bS_horizontal[0, 0] := coef_test_mbedge(mb, mbb, 0, 10);
          mb^.bS_horizontal[1, 0] := coef_test_mbedge(mb, mbb, 1, 11);
          mb^.bS_horizontal[2, 0] := coef_test_mbedge(mb, mbb, 4, 14);
          mb^.bS_horizontal[3, 0] := coef_test_mbedge(mb, mbb, 5, 15);
      end;
  end;
end;



procedure DeblockMBRow(
  const mby: integer;
  const f: frame_t;
  const cqp: boolean = true;
  const offset_a: integer = 0; const offset_b: integer = 0);
var
  p, q: array[0..3] of integer;
  bS_vertical, bS_horizontal: TBSarray;
  filterLeftMbEdgeFlag, filterTopMbEdgeFlag: boolean;

procedure FilterSamplesLuma(const strength, indexA, alpha, beta: integer);
var
  tc, tc0: integer;
  delta, d: integer;
  ap, aq: integer;
  pf, qf: array[0..2] of integer;
  i: integer;
begin
  ap := Abs( p[2] - p[0] );
  aq := Abs( q[2] - q[0] );

  //8.7.2.3 Filtering process for edges with bS less than 4
  if strength < 4 then begin
      tc0 := TAB_TC0[strength, indexA];
      tc  := tc0;
      if ap < beta then tc += 1;
      if aq < beta then tc += 1;

      //Δ = Clip3( –tC, tC, ( ( ( ( q0 – p0 ) << 2 ) + ( p1 – q1 ) + 4 ) >> 3 ) )
      delta := SarLongint( ((q[0] - p[0]) shl 2) + (p[1] - q[1]) + 4, 3 );
      delta := Clip3(-tc, delta, tc);

      //p'1 = p1 + Clip3( –tC0, tC0, ( p2 + ( ( p0 + q0 + 1 ) >> 1 ) – ( p1 << 1 ) ) >> 1 )
      if ap < beta then begin
          d := SarLongint( p[2] + ((p[0] + q[0] + 1) shr 1) - (p[1] shl 1), 1 );
          p[1] := p[1] + Clip3(-tC0, d, tc0);
      end;
      //q'1 = q1 + Clip3( –tC0, tC0, ( q2 + ( ( p0 + q0 + 1 ) >> 1 ) – ( q1 << 1 ) ) >> 1 )
      if aq < beta then begin
          d := SarLongint( q[2] + ((p[0] + q[0] + 1) shr 1) - (q[1] shl 1), 1 );
          q[1] := q[1] + Clip3(-tC0, d, tc0);
      end;

      //p0, q0
      p[0] := clip(p[0] + delta);
      q[0] := clip(q[0] - delta);
  end
  //Filtering process for edges for bS equal to 4
  else begin
      //ap < β && Abs( p0 – q0 ) < ( ( α >> 2 ) + 2 )
      if (ap < beta) and ( abs(p[0] - q[0]) < (alpha shr 2 + 2) ) then begin
          pf[0] := (p[2] + 2*p[1] + 2*p[0] + 2*q[0] + q[1] + 4) shr 3;
          pf[1] := (p[2] + p[1] + p[0] + q[0] + 2) shr 2;
          pf[2] := (2*p[3] + 3*p[2] + p[1] + p[0] + q[0] + 4) shr 3
      end else begin
          pf[0] := (2*p[1] + p[0] + q[1] + 2) shr 2;
          pf[1] := p[1];
          pf[2] := p[2];
      end;

      if (aq < beta) and ( abs(p[0] - q[0]) < (alpha shr 2 + 2) ) then begin
          qf[0] := (q[2] + 2*q[1] + 2*q[0] + 2*p[0] + p[1] + 4) shr 3;
          qf[1] := (q[2] + q[1] + q[0] + p[0] + 2) shr 2;
          qf[2] := (2*q[3] + 3*q[2] + q[1] + q[0] + p[0] + 4) shr 3
      end else begin
          qf[0] := (2*q[1] + q[0] + p[1] + 2) shr 2;
          qf[1] := q[1];
          qf[2] := q[2];
      end;

      for i := 0 to 2 do begin
          p[i] := pf[i];
          q[i] := qf[i];
      end;
  end;
end;

procedure FilterSamplesChroma(const strength, indexA_c: integer);
var
  tc: integer;
  delta: integer;
begin
  //8.7.2.3 Filtering process for edges with bS less than 4
  if strength < 4 then begin
      tc  := TAB_TC0[strength, indexA_c] + 1;
      //Δ = Clip3( –tC, tC, ( ( ( ( q0 – p0 ) << 2 ) + ( p1 – q1 ) + 4 ) >> 3 ) )
      delta := SarLongint( ((q[0] - p[0]) shl 2) + (p[1] - q[1]) + 4, 3 );
      delta := Clip3(-tc, delta, tc);
      //p0, q0
      p[0] := clip(p[0] + delta);
      q[0] := clip(q[0] - delta);
  end
  //Filtering process for edges for bS equal to 4
  else begin
      p[0] := (2*p[1] + p[0] + q[1] + 2) shr 2;
      q[0] := (2*q[1] + q[0] + p[1] + 2) shr 2;
  end;
end;


function UseFilter(alpha, beta: integer): boolean; inline;
begin
  result := (Abs( p[0] - q[0] ) < alpha)
            and (Abs( p[1] - p[0] ) < beta)
            and (Abs( q[1] - q[0] ) < beta);
end;

procedure FilterLuma16x16(const pixel: pbyte; const indexA, alpha, beta: integer);
var
  edge, blk, samples: integer;
  i: integer;
  bs: integer;
  starting_edge: integer;
  pix: pbyte;
  stride: integer;
begin
  stride := f.stride;

  //verticals  - edge = x, blk = y
  starting_edge := 0;
  if not filterLeftMbEdgeFlag then
      starting_edge += 1;

  for edge := starting_edge to 3 do begin
      pix := pixel + edge * 4;

      for blk := 0 to 3 do begin
          bs := bS_vertical[edge, blk];
          if bs = 0 then begin
              pix += 4 * f.stride;
              continue;
          end;

          for samples := 0 to 3 do begin
              for i := 0 to 3 do q[i] := pix[i];
              for i := 0 to 3 do p[i] := pix[-(i+1)];

              if UseFilter(alpha, beta) then begin
                  FilterSamplesLuma(bs, indexA, alpha, beta);
                  for i := 0 to 2 do pix[i] := q[i];
                  for i := 0 to 2 do pix[-(i+1)] := p[i];
              end;

              pix += stride;  //next pixel row
          end;
      end;
  end;

  //horizontals  - edge = y, blk = x
  starting_edge := 0;
  if not filterTopMbEdgeFlag then
      starting_edge += 1;

  for edge := starting_edge to 3 do begin
      pix := pixel + edge * 4 * stride;

      for blk := 0 to 3 do begin
          bs := bS_horizontal[blk, edge];
          if bs = 0 then begin
              pix += 4;
              continue;
          end;

          for samples := 0 to 3 do begin
              for i := 0 to 3 do q[i] := pix[i      * stride];
              for i := 0 to 3 do p[i] := pix[-(i+1) * stride];

              if UseFilter(alpha, beta) then begin
                  FilterSamplesLuma(bs, indexA, alpha, beta);
                  for i := 0 to 2 do pix[i      * stride] := q[i];
                  for i := 0 to 2 do pix[-(i+1) * stride] := p[i];
              end;

              pix += 1;
          end;
      end;
  end;
end;


procedure FilterChroma8x8(const pixel: pbyte; const indexA_c, alpha_c, beta_c: integer);
var
  edge, blk, samples: integer;
  i: integer;
  starting_edge: integer;
  bs: integer;
  pix: pbyte;
  stride: integer;
begin
  stride := f.stride_c;

  //verticals  - edge = x, blk = y
  starting_edge := 0;
  if not filterLeftMbEdgeFlag then
      starting_edge += 1;

  for edge := starting_edge to 1 do begin
      pix := pixel + edge * 4;

      for blk := 0 to 1 do begin
          for samples := 0 to 3 do begin
              for i := 0 to 1 do q[i] := pix[     i];
              for i := 0 to 1 do p[i] := pix[-(i+1)];
              bs := bS_vertical[edge, blk * 2 + samples div 2];

              if (bs > 0) and UseFilter(alpha_c, beta_c) then begin
                  FilterSamplesChroma(bs, indexA_c);
                  pix[ 0] := q[0];
                  pix[-1] := p[0];
              end;

              pix += stride;  //next pixel row
          end;
      end;
  end;

  //horizontals  - edge = y, blk = x
  starting_edge := 0;
  if not filterTopMbEdgeFlag then
      starting_edge += 1;

  for edge := starting_edge to 1 do begin
      pix := pixel + edge * 4 * stride;

      for blk := 0 to 1 do begin
          for samples := 0 to 3 do begin
              for i := 0 to 1 do q[i] := pix[     i * stride];
              for i := 0 to 1 do p[i] := pix[-(i+1) * stride];
              bs := bS_horizontal[blk * 2 + samples div 2, edge];

              if (bs > 0) and UseFilter(alpha_c, beta_c) then begin
                  FilterSamplesChroma(bs, indexA_c);
                  pix[      0] := q[0];
                  pix[-stride] := p[0];
              end;

              pix += 1;
          end;
      end;
  end;
end;


var
  mbx: integer;
  indexA, indexA_c: integer;
  alpha, beta: integer;
  alpha_c, beta_c: integer;

procedure SetupParams(const mb: macroblock_p);
var
  qp, qpc: integer;
  indexB, indexB_c: integer;
begin
  qp := mb^.qp;
  indexA := clip3(0, qp + offset_a, 51);
  indexB := clip3(0, qp + offset_b, 51);
  alpha := TAB_ALPHA[indexA];
  beta  := TAB_BETA [indexB];

  if qp < 30 then begin
      indexA_c := indexA;
      alpha_c := alpha;
      beta_c  := beta;
  end else begin
      qpc := mb^.qpc;
      indexA_c := clip3(0, qpc + offset_a, 51);
      indexB_c := clip3(0, qpc + offset_b, 51);
      alpha_c := TAB_ALPHA[indexA_c];
      beta_c  := TAB_BETA [indexB_c];
  end;
end;

procedure FilterMB(const mb: macroblock_p);
begin
  bS_vertical := mb^.bS_vertical;
  bS_horizontal := mb^.bS_horizontal;
  FilterLuma16x16   (mb^.pfdec,      indexA,   alpha,   beta);
  FilterChroma8x8   (mb^.pfdec_c[0], indexA_c, alpha_c, beta_c);
  FilterChroma8x8   (mb^.pfdec_c[1], indexA_c, alpha_c, beta_c);
end;

var
  mb: macroblock_p;

begin
  if cqp then begin
      //DeblockMBRow params are the same for all mbs
      mb := @f.mbs[0];
      SetupParams(mb);
      filterTopMbEdgeFlag := mby > 0;
      for mbx := 0 to f.mbw - 1 do begin
          filterLeftMbEdgeFlag := mbx > 0;
          mb := @f.mbs[mby * f.mbw + mbx];
          FilterMB(mb);
      end;
  end else begin
      //DeblockMBRow params change according to current mb's qp
      filterTopMbEdgeFlag := mby > 0;
      for mbx := 0 to f.mbw - 1 do begin
          filterLeftMbEdgeFlag := mbx > 0;
          mb := @f.mbs[mby * f.mbw + mbx];
          SetupParams(mb);
          FilterMB(mb);
      end;
  end;
end;


{ TDeblockThread }

procedure TDeblockThread.SetEncodedMBRows(AValue: integer);
begin
  _encoded_mb_rows_lock.Acquire;
  _encoded_mb_rows := AValue;
  _encoded_mb_rows_lock.Release;
end;

function TDeblockThread.GetAbort: boolean;
begin
  _abort_lock.Acquire;
  result := _abort;
  _abort_lock.Release;
end;

function TDeblockThread.GetEncodedMBRows: integer;
begin
  _encoded_mb_rows_lock.Acquire;
  result := _encoded_mb_rows;
  _encoded_mb_rows_lock.Release;
end;

constructor TDeblockThread.Create;
begin
  inherited Create(true);

  _row_processed_event := TSimpleEvent.Create;
  _encoded_mb_rows_lock := TCriticalSection.Create;
  _abort_lock := TCriticalSection.Create;

  _abort := false;
  EncodedMBRows := 0;
end;

destructor TDeblockThread.Free;
begin
  _row_processed_event.Free;
  _encoded_mb_rows_lock.Free;
  _abort_lock.Free;
end;

procedure TDeblockThread.Execute;
var
  mby: integer;
  row_deblock_limit: integer;
  encoded_rows: integer;

begin
  mby := 0;

  while mby < frame^.mbh do begin
      _row_processed_event.WaitFor(INFINITE);
      _row_processed_event.ResetEvent;
      if Abort then
          break;

      encoded_rows := EncodedMBRows;
      if encoded_rows < frame^.mbh then
          row_deblock_limit := encoded_rows - 2
      else
          row_deblock_limit := frame^.mbh;

      //run in a loop: several rows may have been decoded since the last run (event was set multiple times),
      //or the frame is fully decoded
      while (mby < row_deblock_limit) do begin
          DeblockMBRow(mby, frame^, cqp);
          mby += 1;
      end;
  end;
end;

procedure TDeblockThread.IncreaseEncodedMBRows;
begin
  _encoded_mb_rows_lock.Acquire;
  _encoded_mb_rows += 1;
  _encoded_mb_rows_lock.Release;
  _row_processed_event.SetEvent;
end;

procedure TDeblockThread.AbortProcessing;
begin
  _abort_lock.Acquire;
  _abort := true;
  _abort_lock.Release;
  //thread must receive the event to resume its loop and be able to process the abort command
  _row_processed_event.SetEvent;
end;

{ TThreadedDeblocker }

constructor TThreadedDeblocker.Create(const frame: frame_t; const cqp: boolean);
begin
  f := @frame;
  scheduled_mbrows := 0;
  _is_frame_finished := false;

  dthread := TDeblockThread.Create;
  dthread.frame := f;
  dthread.cqp := cqp;

  dthread.Start;
end;

destructor TThreadedDeblocker.Destroy;
begin
  if not _is_frame_finished then
      FrameFinished;
  dthread.Free;
end;

procedure TThreadedDeblocker.MBRowFinished;
begin
  scheduled_mbrows += 1;
  dthread.IncreaseEncodedMBRows;
end;

procedure TThreadedDeblocker.FrameFinished;
begin
  if scheduled_mbrows < f^.mbh then
      dthread.AbortProcessing;
  dthread.WaitFor;
  _is_frame_finished := true;
end;

{ TSimpleDeblocker }

constructor TSimpleDeblocker.Create(const frame: frame_t; const cqp: boolean);
begin
  f := @frame;
  _cqp := cqp;
  scheduled_mbrows := 0;
end;

procedure TSimpleDeblocker.FrameFinished;
var
  mby: integer;
begin
  if scheduled_mbrows = f^.mbh then
      for mby := 0 to f^.mbh - 1 do begin
          DeblockMBRow(mby, f^, _cqp);
      end;
end;

procedure TSimpleDeblocker.MBRowFinished;
begin
  scheduled_mbrows += 1;
end;


end.


