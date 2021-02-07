unit loopfilter_threading;
{$mode objfpc}{$H+}

interface

uses
  common, frame, classes, sysutils, syncobjs, loopfilter;

type

  { TDeblockThread }
  TDeblockThread = class(TThread)
    private
      _new_frame_event: TSimpleEvent;
      _finished_frame_event: TSimpleEvent;
      _row_processed_event: TSimpleEvent;
      _abort_lock: TCriticalSection;

      _frame: frame_p;
      _encoded_mb_rows: integer;
      _filter_ab_offset: int8;
      _cqp: boolean;
      _abort: boolean;

      function CheckAbort: boolean;
      procedure DeblockRows;

    public
      constructor Create(const filter_offset: int8);
      destructor Destroy; override;

      procedure Execute; override;
      procedure BeginFrame(frame: frame_p; const cqp: boolean = true);
      procedure WaitEndFrame();
      procedure IncreaseEncodedMBRows;
      procedure AbortProcessing;
  end;

  { TDeblocker
    Deblocks in paralell with encoding; running a few macroblock rows behind the encoding thread
  }
  TDeblocker = class
    private
      dthread: TDeblockThread;
    public
      constructor Create(const filter_offset: int8);
      destructor Destroy; override;
      procedure BeginFrame(const frame: frame_t; const cqp: boolean = true);
      procedure MBRowFinished;
      procedure FinishFrame(abort: boolean = false);
  end;


implementation

{ TDeblockThread }

constructor TDeblockThread.Create(const filter_offset: int8);
begin
  inherited Create(true);
  _new_frame_event := TSimpleEvent.Create;
  _finished_frame_event := TSimpleEvent.Create;
  _row_processed_event := TSimpleEvent.Create;
  _abort_lock := TCriticalSection.Create;
  _filter_ab_offset := filter_offset;
end;

destructor TDeblockThread.Destroy;
begin
  _new_frame_event.Free;
  _finished_frame_event.Free;
  _row_processed_event.Free;
  _abort_lock.Free;
end;

function TDeblockThread.CheckAbort: boolean;
begin
  _abort_lock.Acquire;
  result := _abort;
  _abort_lock.Release;
end;

procedure TDeblockThread.BeginFrame(frame: frame_p; const cqp: boolean);
begin
  _frame := frame;
  _encoded_mb_rows := 0;
  _cqp := cqp;
  _abort := false;
  _new_frame_event.SetEvent;
end;

procedure TDeblockThread.WaitEndFrame();
begin
  _finished_frame_event.WaitFor(INFINITE);
  _finished_frame_event.ResetEvent;
end;

procedure TDeblockThread.IncreaseEncodedMBRows;
begin
  _encoded_mb_rows += 1; //there is only one writer thread, so interlocked is not needed
  _row_processed_event.SetEvent;
end;

procedure TDeblockThread.Execute;
begin
  repeat
      _new_frame_event.WaitFor(INFINITE);
      _new_frame_event.ResetEvent;
      if _frame <> nil then begin
          DeblockRows;
          _finished_frame_event.SetEvent;
      end
      else
          break;
  until false;
end;

procedure TDeblockThread.DeblockRows;
var
  mby: integer;
  row_deblock_limit: integer;
begin
  mby := 0;
  while mby < _frame^.mbh do begin
      _row_processed_event.WaitFor(INFINITE);
      _row_processed_event.ResetEvent;
      if CheckAbort() then
          break;

      row_deblock_limit := _encoded_mb_rows - 1;
      if _encoded_mb_rows = _frame^.mbh then
          row_deblock_limit := _frame^.mbh;

      //run in a loop: several rows may have been decoded since the last run (event was set multiple times),
      //or the frame is fully decoded
      while (mby < row_deblock_limit) do begin
          DeblockMBRow(mby, _frame^, _cqp, _filter_ab_offset, _filter_ab_offset);
          if mby > 0 then
              frame_decoded_macroblock_row_ssd(_frame, mby - 1);
          mby += 1;
      end;
  end;
  frame_decoded_macroblock_row_ssd(_frame, _frame^.mbh - 1);
end;

procedure TDeblockThread.AbortProcessing;
begin
  _abort_lock.Acquire;
  _abort := true;
  _abort_lock.Release;
  //thread must receive the event to resume its loop and be able to process the abort command
  _row_processed_event.SetEvent;
end;

{ TDeblocker }

constructor TDeblocker.Create(const filter_offset: int8);
begin
  dthread := TDeblockThread.Create(filter_offset);
  dthread.Start;
end;

destructor TDeblocker.Destroy;
begin
  dthread.BeginFrame(nil);
  dthread.WaitFor;
  dthread.Free;
end;

procedure TDeblocker.BeginFrame(const frame: frame_t; const cqp: boolean);
begin
  dthread.BeginFrame(@frame, cqp);
end;

procedure TDeblocker.MBRowFinished;
begin
  dthread.IncreaseEncodedMBRows;
end;

procedure TDeblocker.FinishFrame(abort: boolean);
begin
  if abort then
      dthread.AbortProcessing;
  dthread.WaitEndFrame();
end;


end.

(*******************************************************************************
loopfilter_thread.pas
Copyright (c) 2019 David Pethes

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

