(*******************************************************************************
motion_est.pas
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

unit motion_est;
{$mode objfpc}{$H+}

interface

uses
  common, util, motion_comp, inter_pred, motion_est_search, h264stream;

type
  TScoreListItem = record
      score: integer;
      mv: motionvec_t;
      refidx: integer;
  end;

  { TMotionEstimator }

  TMotionEstimator = class
    private
      width, height: integer;
      mb_width, mb_height: integer;
      mv_field: motionvec_p;
      predicted_mv_list: TMotionVectorList;
      ref_count: integer;
      _subme: integer;

      SearchRegion: TRegionSearch;
      InterCost: TInterPredCost;

      procedure EstimateMultiRef(var mb: macroblock_t; var fenc: frame_t);
      procedure EstimateSingleRef(var mb: macroblock_t; var fenc: frame_t);
      procedure LoadMVPredictors(const mbx, mby: integer);
      class function ClipMVRange(const mv: motionvec_t): motionvec_t; inline;
      procedure SetNumReferences(AValue: integer);
      procedure SetSubMELevel(AValue: integer);

    public
      property Subme: integer read _subme write SetSubMELevel;

      property NumReferences: integer read ref_count write SetNumReferences;
      constructor Create(const w, h, mbw, mbh: integer; h264stream: TH264Stream);
      destructor Free;
      procedure Estimate(var mb: macroblock_t; var fenc: frame_t);
      procedure Estimate_16x8(var mb: macroblock_t);
      procedure Refine(var mb: macroblock_t);
      procedure Skipped(var mb: macroblock_t);
  end;


(*******************************************************************************
*******************************************************************************)
implementation

procedure swapItem(var a, b: TScoreListItem); inline;
var
  t: TScoreListItem;
begin
  t := a;
  a := b;
  b := t;
end;


{ TMotionEstimator }

procedure TMotionEstimator.LoadMVPredictors(const mbx, mby: integer);
var
  mv_a, mv_b: motionvec_t;
begin
  //A, B, avg
  if mbx > 0 then begin
      mv_a := mv_field[mby * mb_width + mbx - 1];
      predicted_mv_list.Add(mv_a);
  end else
      mv_a := ZERO_MV;
  if mby > 0 then begin
      mv_b := mv_field[(mby - 1) * mb_width + mbx];
      predicted_mv_list.Add(mv_b);
  end else
      mv_b := ZERO_MV;
  if not (mv_a = mv_b) then
      predicted_mv_list.Add((mv_a + mv_b) / 2);

  //C, D
  if (mby > 0) and (mbx < mb_width - 1) then
      predicted_mv_list.Add( mv_field[ (mby - 1) * mb_width + mbx + 1] );
  if (mby > 0) and (mbx > 0) then
      predicted_mv_list.Add( mv_field[ (mby - 1) * mb_width + mbx - 1] );

  //last frame: same position, right
  predicted_mv_list.Add( mv_field[mby * mb_width + mbx] );
  if mbx < mb_width - 2 then
      predicted_mv_list.Add( mv_field[mby * mb_width + mbx + 1] );

  //last frame: directly below, left/right
  if mby < mb_height - 2 then begin
      predicted_mv_list.Add( mv_field[mby * mb_width + mbx + mb_width] );
      if (mbx > 0) then
          predicted_mv_list.Add( mv_field[mby * mb_width + mbx - 1 + mb_width] );
      if (mbx < mb_width - 1) then
          predicted_mv_list.Add( mv_field[mby * mb_width + mbx + 1 + mb_width] );
  end;
end;

{ Vertical range depends on level; 3.1 and higher is -2048..2047 in qpel units,
  horizontal range is -8192..8191 in qpel units.
  However the max delta(mv, mvp) is limited by EG codes table size used for vlc writing.
}
class function TMotionEstimator.ClipMVRange(const mv: motionvec_t): motionvec_t;
const
  RANGE = EG_MAX_ABS div 2;
begin
  result := XYToMVec(clip3(-RANGE, mv.x, RANGE), clip3(-RANGE, mv.y, RANGE));
end;

procedure TMotionEstimator.SetNumReferences(AValue: integer);
begin
  if ref_count = AValue then Exit;
  ref_count := AValue;
end;

procedure TMotionEstimator.SetSubMELevel(AValue: integer);
begin
  _subme := AValue;
end;

constructor TMotionEstimator.Create(const w, h, mbw, mbh: integer; h264stream: TH264Stream);
var
  size: integer;
begin
  width  := w;
  height := h;
  mb_width  := mbw;
  mb_height := mbh;
  size := mbw * mbh * sizeof(motionvec_t);
  mv_field := getmem(size);
  fillbyte(mv_field^, size, 0);
  SetNumReferences(1);

  predicted_mv_list.Clear;

  InterCost := h264stream.InterPredCost;
  SearchRegion := TRegionSearch.Create(width, height, h264stream);
end;

destructor TMotionEstimator.Free;
begin
  freemem(mv_field);
  SearchRegion.Free;
end;


procedure TMotionEstimator.Estimate(var mb: macroblock_t; var fenc: frame_t);
var
  lowres_mv: motionvec_t;
  lowres_mb_idx: Integer;
begin
  SearchRegion.cur := mb.pixels;
  SearchRegion._mbx := mb.x * 16;
  SearchRegion._mby := mb.y * 16;
  InterCost.SetQP(mb.qp);

  predicted_mv_list.Clear;
  predicted_mv_list.Add(mb.mvp);
  if fenc.lowres <> nil then begin
      lowres_mb_idx := (mb.y div 2) * fenc.lowres^.mbw + (mb.x div 2);
      lowres_mv := fenc.lowres^.mbs[lowres_mb_idx].mv * 2;
      predicted_mv_list.Add(lowres_mv);

      //topmost row lacks predictors, so take some more from lowres ME
      if mb.y = 0 then begin
          if mb.x < mb_width - 1 then begin
              lowres_mv := fenc.lowres^.mbs[lowres_mb_idx + 1].mv * 2;
              predicted_mv_list.Add(lowres_mv);
          end;
      end;
  end;
  LoadMVPredictors(mb.x, mb.y);

  if NumReferences = 1 then
      EstimateSingleRef(mb, fenc)
  else
      EstimateMultiRef(mb, fenc);
  mv_field[mb.y * mb_width + mb.x] := mb.mv;
end;


procedure TMotionEstimator.EstimateSingleRef(var mb: macroblock_t; var fenc: frame_t);
var
  fref: frame_p;
begin
  mb.fref := fenc.refs[0];
  fref := mb.fref;
  InterCost.SetMVPredAndRefIdx(mb.mvp, 0);

  SearchRegion.PickFPelStartingPoint(fref, predicted_mv_list);
  mb.mv := SearchRegion.SearchFPel(mb, fref);

  if _subme > 0 then
      mb.mv := SearchRegion.SearchHPel(mb, fref);
  if _subme > 1 then
      mb.mv := SearchRegion.SearchQPel(mb, fref, _subme > 2, _subme > 3);

  mb.mv := ClipMVRange(mb.mv);
  MotionCompensation.Compensate(fref, mb);
end;

procedure TMotionEstimator.Refine(var mb: macroblock_t);
var
  mv: motionvec_t;
begin
  if _subme < 5 then
      exit;

  mv := mb.mv;
  SearchRegion.SearchQPelRDO(mb, mb.fref);
  if mv <> mb.mv then begin
      ClipMVRange(mb.mv);
      mv_field[mb.y * mb_width + mb.x] := mb.mv;
  end;

  MotionCompensation.Compensate(mb.fref, mb);
end;

procedure TMotionEstimator.Skipped(var mb: macroblock_t);
begin
  mv_field[mb.y * mb_width + mb.x] := mb.mv;
end;


procedure TMotionEstimator.EstimateMultiRef(var mb: macroblock_t; var fenc: frame_t);
var
  i: integer;
  score: integer;
  mv: motionvec_t;
  best_refidx, best_score, best_hpel_score: integer;
  fref: frame_p;
  min_score: integer;
  fpel_scores: array[0..15] of TScoreListItem;
  refine_candidates: array of TScoreListItem;

begin
  mb.fref := fenc.refs[0];
  fref := mb.fref;
  min_score := MaxInt;

  //fpel test
  for i := 0 to ref_count - 1 do begin
      fref := fenc.refs[i];
      SearchRegion.PickFPelStartingPoint(fref, predicted_mv_list);
      fpel_scores[i].mv := SearchRegion.SearchFPel(mb, fref);
      fpel_scores[i].score := SearchRegion.LastSearchScore;
      fpel_scores[i].refidx := i;
      min_score := min(min_score, fpel_scores[i].score);
  end;

  min_score := min_score * 2;
  if min_score = 0 then
      min_score := 1;
  for i := 0 to ref_count - 1 do begin
      if fpel_scores[i].score < min_score then
          Insert(fpel_scores[i], refine_candidates, MaxInt);
  end;

  //hpel/qpel
  best_hpel_score := MaxInt;
  best_score := MaxInt;
  best_refidx := 0;
  mv := ZERO_MV;
  for i := 0 to High(refine_candidates) do begin
      mb.mv  := refine_candidates[i].mv;
      mb.ref := refine_candidates[i].refidx;
      fref := fenc.refs[mb.ref];

      InterCost.SetMVPredAndRefIdx(mb.mvp, mb.ref);
      mb.mv := SearchRegion.SearchHPel(mb, fref);
      score := SearchRegion.LastSearchScore;
      if score < best_hpel_score then
          best_hpel_score := score;
      if score > best_hpel_score * 7 div 5 then  //don't try qpel if the hpel is 1,4x worse
          continue;

      mb.mv := SearchRegion.SearchQPel(mb, fref, _subme > 2, _subme > 3);
      score := SearchRegion.LastSearchScore;
      if score < best_score then begin
          mv := mb.mv;
          best_refidx := mb.ref;
          best_score := score;
      end;
  end;

  //restore best
  fref := fenc.refs[best_refidx];
  mb.ref := best_refidx;
  mb.fref := fref;
  if mb.ref > 0 then  //mvp for refidx != 0 can differ from the inital mvp
      InterPredLoadMvs(mb, fenc, ref_count);

  mb.mv := ClipMVRange(mv);
  MotionCompensation.Compensate(fref, mb);
end;


procedure TMotionEstimator.Estimate_16x8(var mb: macroblock_t);
var
  mv0, mv1: motionvec_t;
begin
  //mb.mv is used as a starting point for both partitions, so don't overwrite it just yet
  mb.mv1 := mb.mv;
  mv0 := SearchRegion.SearchQPel_16x8_partition(mb, 0, mb.fref, _subme > 2, _subme > 3);
  mv1 := SearchRegion.SearchQPel_16x8_partition(mb, 1, mb.fref, _subme > 2, _subme > 3);

  ClipMVRange(mv0);
  ClipMVRange(mv1);
  mb.mv  := mv0;
  mb.mv1 := mv1;
  mv_field[mb.y * mb_width + mb.x] := mv1;

  MotionCompensation.Compensate_16x8(mb.fref, mb, 0);
  MotionCompensation.Compensate_16x8(mb.fref, mb, 1);
end;


end.

