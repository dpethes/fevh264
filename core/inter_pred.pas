unit inter_pred;

{$mode objfpc}{$H+}

interface

uses
  common, util;

procedure mb_load_mvs
  (var mb: macroblock_t; const frame: frame_t; const num_ref_frames: integer);


implementation

(*******************************************************************************
calculate predicted mv, store some mvs as predictors for ME
mb layout:
  D B C
  A X
*)
procedure mb_load_mvs
  (var mb: macroblock_t; const frame: frame_t; const num_ref_frames: integer);

  function is_avail(const mb: macroblock_p): boolean; inline;
  begin
    result := not( mb^.mbtype in [MB_I_4x4, MB_I_16x16] );
  end;

type
  mb_info = record
    avail: boolean;
    mv: motionvec_t;
    refidx: integer;
  end;

var
  mbs: array[0..2] of mb_info; //A, B, C (D)
  t: macroblock_p;
  i: integer;
  num_avail: integer;
  same_ref_n: integer;
  same_ref_i: integer;

procedure assign_mb(var m: mb_info); inline;
begin
  m.avail  := is_avail(t);
  m.mv     := t^.mv;
  m.refidx := t^.ref;
  if m.avail then
      num_avail += 1;
end;

begin
  if frame.ftype = SLICE_I then
      exit;

  mb.mv := ZERO_MV;
  num_avail := 0;
  for i := 0 to 2 do begin
      mbs[i].avail := false;
      mbs[i].mv := ZERO_MV;
      mbs[i].refidx := 0;
  end;

  //left mb - A
  if mb.x > 0 then begin
      t := @frame.mbs[ mb.y * frame.mbw + mb.x - 1];
      assign_mb(mbs[0]);
  end;

  //top mbs - B, C/D
  if mb.y > 0 then begin
      t := @frame.mbs[ (mb.y - 1) * frame.mbw + mb.x];
      assign_mb(mbs[1]);

      if mb.x < frame.mbw - 1 then
          t := @frame.mbs[ (mb.y - 1) * frame.mbw + mb.x + 1]  //C
      else
          t := @frame.mbs[ (mb.y - 1) * frame.mbw + mb.x - 1]; //D
      assign_mb(mbs[2]);
  end;

  case num_avail of
      0:
          mb.mvp := ZERO_MV;

      1: begin
          //only one mb is available for interpred - use its mv (if the refidx is the same)
          for i := 0 to 2 do
              if mbs[i].avail then begin
                  mb.mvp := mbs[i].mv;
                  if (num_ref_frames > 1) and (mb.y > 0) and (mbs[i].refidx <> mb.ref) then
                      mb.mvp := ZERO_MV;
              end;
      end;

      2, 3: begin
          //mvp = median (a, b ,c)
          mb.mvp.x := median(mbs[0].mv.x, mbs[1].mv.x, mbs[2].mv.x);
          mb.mvp.y := median(mbs[0].mv.y, mbs[1].mv.y, mbs[2].mv.y);

          //only one mb has same refidx - 8.4.1.3.1
          if (num_ref_frames > 1) then begin
              same_ref_n := 0;
              same_ref_i := 0;
              for i := 0 to 2 do
                  if mbs[i].avail and (mbs[i].refidx = mb.ref) then begin
                      same_ref_n += 1;
                      same_ref_i := i;
                  end;
              if same_ref_n = 1 then
                  mb.mvp := mbs[same_ref_i].mv;
          end;
      end;

  end;

  //get skip mv from predicted mv (for P_SKIP) - 8.4.1.1
  mb.mv_skip := mb.mvp;
  //frame edge
  if (mb.x = 0) or (mb.y = 0) then
      mb.mv_skip := ZERO_MV;
  //A
  if mb.x > 0 then
      if mbs[0].avail and (mbs[0].mv = ZERO_MV) and (mbs[0].refidx = 0) then
          mb.mv_skip := ZERO_MV;
  //B
  if mb.y > 0 then
      if mbs[1].avail and (mbs[1].mv = ZERO_MV) and (mbs[1].refidx = 0) then
          mb.mv_skip := ZERO_MV;
end;



end.

