(*******************************************************************************
motion_est_search.pas
Copyright (c) 2012-2017 David Pethes

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

unit motion_est_search;
{$mode objfpc}{$H+}

interface

uses
  common, util, motion_comp, frame, h264stream, macroblock;

type
  { TRegionSearch }

  TRegionSearch = class
    private
      _max_x, _max_y: integer;
      _max_x_hpel, _max_y_hpel: integer;
      _max_x_qpel, _max_y_qpel: integer;
      _last_search_score: integer;
      _starting_fpel_mv: motionvec_t;
      InterCost: TInterPredCost;
      h264s: TH264Stream;

    public
      cur: pbyte;
      _mbx, _mby: integer;

      property LastSearchScore: integer read _last_search_score;

      constructor Create(region_width, region_height: integer; h264stream: TH264Stream);
      procedure PickFPelStartingPoint(const fref: frame_p; const predicted_mv_list: TMotionVectorList);
      function SearchFPel(var mb: macroblock_t; const fref: frame_p): motionvec_t;
      function SearchHPel(var mb: macroblock_t; const fref: frame_p): motionvec_t;
      function SearchQPel(var mb: macroblock_t; const fref: frame_p; const satd, chroma_me: boolean): motionvec_t;
      procedure SearchQPelRDO(var mb: macroblock_t; const fref: frame_p);
      function SearchQPel_16x8_partition(var mb: macroblock_t; idx: integer; const fref: frame_p; const satd, chroma_me: boolean): motionvec_t;
 end;

(*******************************************************************************
*******************************************************************************)
implementation

type
  //motion search patterns
  TXYOffs = array[0..1] of int8;
  TMEPrecision = (mpFpel, mpHpel, mpQpel);

const
  FPEL_SAD_TRESH = 64;
  ME_RANGES: array [TMEPrecision] of byte = (16, 4, 4);
  MIN_XY = -FRAME_EDGE_W;
  MIN_XY_HPEL = MIN_XY * 2;
  MIN_XY_QPEL = MIN_XY * 4;
  pt_dia_small: array[0..3] of TXYOffs =
      ( (0, -1), (0, 1), (-1, 0), (1, 0) );
  {
  pt_dia_large: array[0..7] of TXYOffs =
      ( (0, -2), (0, 2), (-2, 0), (2, 0), (-1, -1), (-1, 1), (1, -1), (1, 1) );
      }
  pt_dia_large_sparse: array[0..3] of TXYOffs =
      ( (0, -2), (0, 2), (-2, 0), (2, 0) );
  pt_square: array[0..7] of TXYOffs =
      ( (0, -1), (0, 1), (-1, 0), (1, 0), (-1, -1), (-1, 1), (1, -1), (1, 1) );

constructor TRegionSearch.Create(region_width, region_height: integer; h264stream: TH264Stream);
var
  edge: integer;
begin
  H264s := h264stream;
  InterCost := H264s.InterPredCost;

  _starting_fpel_mv  := ZERO_MV;
  _last_search_score := MaxInt;

  //max. compensated mb position; we need to subtract the unpainted edge
  edge := FRAME_EDGE_W + 1;
  _max_x := region_width  - edge;
  _max_y := region_height - edge;

  edge := FRAME_EDGE_W * 2 + 1;
  _max_x_hpel := region_width  * 2 - edge;
  _max_y_hpel := region_height * 2 - edge;

  edge := FRAME_EDGE_W * 4 + 1;
  _max_x_qpel := region_width  * 4 - edge;
  _max_y_qpel := region_height * 4 - edge;
end;

(*
Pick a FPel mv that gives the lowest SAD score from a list of predictors.
This mv will be the starting point for FPel search.
input
  fref - frame being searched
  me - ME struct set up for fpel
  predicted_mv_list - list of predicted mvs in QPel units
*)
procedure TRegionSearch.PickFPelStartingPoint(const fref: frame_p; const predicted_mv_list: TMotionVectorList);
var
  i, x, y: integer;
  stride: integer;
  score: integer;
  ref: pbyte;
  tested_mv: motionvec_t;

begin
  ref := fref^.plane_dec[0];
  stride := fref^.stride;

  //test 0,0
  _last_search_score := dsp.sad_16x16(cur, @ref[stride * _mby + _mbx], stride);
  _starting_fpel_mv  := ZERO_MV;

  //test vectors
  for i := 0 to predicted_mv_list.Count - 1 do begin
      tested_mv := predicted_mv_list[i] / 4;
      if tested_mv = ZERO_MV then
          continue;

      x := clip3 (MIN_XY, _mbx + tested_mv.x, _max_x);
      y := clip3 (MIN_XY, _mby + tested_mv.y, _max_y);
      score := dsp.sad_16x16(cur, @ref[stride * y + x], stride);

      if score < _last_search_score then begin
          _last_search_score := score;
          _starting_fpel_mv := XYToMVec(x - _mbx, y - _mby);
      end;
  end;
end;

(*
Fullpel ME search using 8-point diamond pattern
output
  result - best found vector (in qpel units)
*)
function TRegionSearch.SearchFPel(var mb: macroblock_t; const fref: frame_p): motionvec_t;
var
  ref: pbyte;
  max_x, max_y: integer;
  x, y: integer;         //currently searched fpel x,y position
  stride: integer;
  min_score: integer;
  mv, mv_prev_pass: motionvec_t;
  iter: integer;
  check_bounds: boolean;
  range: integer;
  pixel_range: integer;

procedure check_pattern(const pattern: array of TXYOffs);
var
  i: integer;
  nx, ny: integer;
  score: integer;
begin
  if check_bounds then
      if (x - 2 < MIN_XY) or (x + 2 > max_x) or
         (y - 2 < MIN_XY) or (y + 2 > max_y) then exit;
  for i := 0 to Length(pattern) - 1 do begin
      nx := x + pattern[i][0];
      ny := y + pattern[i][1];
      score := dsp.sad_16x16(cur, @ref[stride * ny + nx], stride);
      if score < min_score then begin
          min_score := score;
          mv := XYToMVec(nx - _mbx, ny - _mby);
      end;
  end;
  x := _mbx + mv.x;
  y := _mby + mv.y;
end;


begin
  if _last_search_score < FPEL_SAD_TRESH then begin
      mb.mv := _starting_fpel_mv * 4;
      result := mb.mv;
      exit;
  end;

  ref    := fref^.plane_dec[0];
  stride := fref^.stride;
  max_x  := _max_x;
  max_y  := _max_y;
  range  := ME_RANGES[mpFpel];

  mv := _starting_fpel_mv;
  x := _mbx + mv.x;
  y := _mby + mv.y;
  min_score := _last_search_score;

  iter := 0;
  pixel_range := 2 * range + 1; //use large diamond range
  check_bounds := (x - pixel_range < MIN_XY) or (x + pixel_range > max_x) or
                  (y - pixel_range < MIN_XY) or (y + pixel_range > max_y);
  repeat
      mv_prev_pass := mv;
      check_pattern(pt_dia_large_sparse);
      iter += 1;
  until (mv = mv_prev_pass) or (iter >= range);
  check_pattern(pt_square);
  _last_search_score := min_score;

  //scale mv to qpel units
  mb.mv := mv * 4;
  result := mb.mv;
end;


(*
Half-pixel ME search using 4-point diamond pattern
input
  mb.mv - starting vector in qpel units
  fref^.luma_mc - 4 half-pel interpolated planes
output
  result - best found vector (in qpel units)
*)
function TRegionSearch.SearchHPel(var mb: macroblock_t; const fref: frame_p): motionvec_t;
var
  ref: array[0..3] of pbyte;
  max_x, max_y: integer;
  mbx, mby,              //macroblock hpel x,y position
  x, y: integer;         //currently searched hpel x,y position
  stride: integer;
  min_score: integer;
  mv,
  mv_prev_pass: motionvec_t;
  range: integer;
  iter: integer;
  check_bounds: boolean;

procedure check_pattern_hpel();
var
  i, idx: integer;
  nx, ny,
  mcx, mcy: integer;
  score: integer;
begin
  for i := 0 to 3 do begin
      nx := x + pt_dia_small[i][0];
      ny := y + pt_dia_small[i][1];

      mcx := nx div 2;
      mcy := ny div 2;
      idx := ((ny and 1) shl 1) or (nx and 1);
      score := dsp.sad_16x16(cur, ref[idx] + mcy * stride + mcx, stride)
               + InterCost.Bits((nx - mbx) * 2, (ny - mby) * 2);

      if score < min_score then begin
          min_score := score;
          mv := XYToMVec(nx - mbx, ny - mby);
      end;
  end;
  x := mbx + mv.x;
  y := mby + mv.y;
end;

begin
  for x := 0 to 3 do
      ref[x] := fref^.luma_mc[x];
  stride := fref^.stride;
  mbx    := _mbx * 2;
  mby    := _mby * 2;
  max_x  := _max_x_hpel;
  max_y  := _max_y_hpel;
  range  := ME_RANGES[mpHpel];

  //scale to hpel units
  mv := mb.mv / 2;
  x := mbx + mv.x;
  y := mby + mv.y;
  min_score := MaxInt;  //we need to include bitcost in score, so reset

  iter := 0;
  check_bounds := (x - range < MIN_XY_HPEL) or (x + range > max_x)
               or (y - range < MIN_XY_HPEL) or (y + range > max_y);
  repeat
      mv_prev_pass := mv;
      if check_bounds then
          if (x - 1 < MIN_XY_HPEL) or (x + 1 > max_x) or
             (y - 1 < MIN_XY_HPEL) or (y + 1 > max_y) then break;
      check_pattern_hpel;
      iter += 1;
  until (mv = mv_prev_pass) or (iter >= range);
  _last_search_score := min_score;

  //scale mv to qpel units
  mb.mv := mv * 2;
  result := mb.mv;
end;


(* quarter-pixel motion vector refinement - search using 4-point diamond pattern
  input
    me - ME struct set up for qpel
    h.mb.mv - starting vector in qpel units
  output
    h.mb.mv - best found vector in qpel units
*)
function TRegionSearch.SearchQPel
  (var mb: macroblock_t; const fref: frame_p; const satd, chroma_me: boolean): motionvec_t;
var
  mbcmp: mbcmp_func_t;
  max_x, max_y: integer;
  mbx, mby,              //macroblock qpel x,y position
  x, y: integer;         //currently searched qpel x,y position
  min_score: integer;
  mv,
  mv_prev_pass: motionvec_t;
  range: integer;
  iter: integer;
  check_bounds: boolean;

procedure check_pattern_qpel();
var
  i: integer;
  nx, ny,
  score: integer;
begin
  for i := 0 to 3 do begin
      nx := x + pt_dia_small[i][0];
      ny := y + pt_dia_small[i][1];

      MotionCompensation.CompensateQPelXY(fref, nx, ny, mb.mcomp);
      score := mbcmp(cur, mb.mcomp, 16)
               + InterCost.Bits(nx - mbx, ny - mby);

      if chroma_me then begin
          MotionCompensation.CompensateChromaQpelXY(fref, nx, ny, mb.mcomp_c[0], mb.mcomp_c[1]);
          score += dsp.satd_8x8(mb.pixels_c[0], mb.mcomp_c[0], 16) +
                   dsp.satd_8x8(mb.pixels_c[1], mb.mcomp_c[1], 16);
      end;

      if score < min_score then begin
          min_score := score;
          mv := XYToMVec(nx - mbx, ny - mby);
      end;
  end;
  x := mbx + mv.x;
  y := mby + mv.y;
end;

begin
  mbx    := _mbx * 4;
  mby    := _mby * 4;
  max_x  := _max_x_qpel;
  max_y  := _max_y_qpel;
  if satd then
      mbcmp := dsp.satd_16x16  //chroma_me always uses satd
  else
      mbcmp := dsp.sad_16x16;
  range  := ME_RANGES[mpQpel];

  mv := mb.mv;
  x := mbx + mv.x;
  y := mby + mv.y;
  min_score := MaxInt;  //reset score, mbcmp may be different

  iter := 0;
  check_bounds := (x - range < MIN_XY_QPEL) or (x + range > max_x) or
                  (y - range < MIN_XY_QPEL) or (y + range > max_y);
  repeat
      mv_prev_pass := mv;
      if check_bounds then
          if (x - 1 < MIN_XY_QPEL) or (x + 1 > max_x) or
             (y - 1 < MIN_XY_QPEL) or (y + 1 > max_y) then break;
      check_pattern_qpel();
      iter += 1;
  until (mv = mv_prev_pass) or (iter >= range);

  if min_score = MaxInt then begin    //return valid score if no searches were done (rare cases at the padded edge of a frame)
      MotionCompensation.CompensateQPelXY(fref, x, y, mb.mcomp);
      min_score := mbcmp(cur, mb.mcomp, 16) + InterCost.Bits(mv);
      if chroma_me then begin
          MotionCompensation.CompensateChromaQpelXY(fref, x, y, mb.mcomp_c[0], mb.mcomp_c[1]);
          min_score += dsp.satd_8x8(mb.pixels_c[0], mb.mcomp_c[0], 16) +
                       dsp.satd_8x8(mb.pixels_c[1], mb.mcomp_c[1], 16);
      end;
  end;

  _last_search_score := min_score;
  mb.mv := mv;
  result := mv;
end;



procedure TRegionSearch.SearchQPelRDO(var mb: macroblock_t; const fref: frame_p);
const
{ for qp in range(15,52):
    lx = 0.85 * pow(2, (qp-12) / 3.2)
}
  LAMBDA_ME: array[0..QP_MAX] of uint16 = (
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 2, 2, 3, 3, 4,
    5, 6, 7, 9, 11, 14, 18, 22, 27, 34, 42,
    52, 65, 80, 100, 124, 154, 191, 237, 295, 366,
    454, 564, 701, 870, 1081, 1342, 1667, 2070, 2571,
    3193, 3965
  );
var
  max_x, max_y: integer;
  mbx, mby,              //macroblock qpel x,y position
  x, y: integer;         //currently searched qpel x,y position
  min_score: integer;
  lambda: integer;
  mv,
  mv_prev_pass, initial_mv: motionvec_t;
  range: integer;
  iter: integer;
  check_bounds: boolean;

function GetCost: integer;
begin
  //bitcost first, decoding modifies dct coefs in-place
  result := h264s.GetBitCost(mb) * lambda;
  decode_mb_inter(mb);
  decode_mb_chroma(mb, false);
  result += dsp.ssd_16x16(mb.pixels, mb.pixels_dec, 16);
  result += dsp.ssd_8x8(mb.pixels_c[0], mb.pixels_dec_c[0], 16)
          + dsp.ssd_8x8(mb.pixels_c[1], mb.pixels_dec_c[1], 16);
end;

procedure check_pattern_qpel;
var
  i: integer;
  nx, ny,
  score: integer;
begin
  for i := 0 to 3 do begin
      nx := x + pt_dia_small[i][0];
      ny := y + pt_dia_small[i][1];

      mb.mv := XYToMVec(nx - mbx, ny - mby);
      if (mb.mv = initial_mv) then
          continue;

      MotionCompensation.CompensateQPelXY(fref, nx, ny, mb.mcomp);
      MotionCompensation.CompensateChromaQpelXY(fref, nx, ny, mb.mcomp_c[0], mb.mcomp_c[1]);
      encode_mb_inter(mb);
      encode_mb_chroma(mb, false);

      score := GetCost;
      if score < min_score then begin
          min_score := score;
          mv := mb.mv
      end;
  end;
  x := mbx + mv.x;
  y := mby + mv.y;
end;

begin
  mbx    := _mbx * 4;
  mby    := _mby * 4;
  max_x  := _max_x_qpel;
  max_y  := _max_y_qpel;
  range  := 2;
  initial_mv := mb.mv;

  mv := mb.mv;
  x := mbx + mv.x;
  y := mby + mv.y;
  lambda := LAMBDA_ME[mb.qp];
  min_score := GetCost;

  iter := 0;
  check_bounds := (x - range < MIN_XY_QPEL) or (x + range > max_x) or
                  (y - range < MIN_XY_QPEL) or (y + range > max_y);
  repeat
      mv_prev_pass := mv;
      if check_bounds then
          if (x - 1 < MIN_XY_QPEL) or (x + 1 > max_x) or
             (y - 1 < MIN_XY_QPEL) or (y + 1 > max_y) then break;
      check_pattern_qpel();
      iter += 1;
  until (mv = mv_prev_pass) or (iter >= range);

  _last_search_score := min_score;
  mb.mv := mv;
end;
  

//mb.mcomp isn't adjusted, as it gets properly written at end of ME
//cur needs to be offset, but maybe do it differently?
function TRegionSearch.SearchQPel_16x8_partition(var mb: macroblock_t; idx: integer;
  const fref: frame_p; const satd, chroma_me: boolean): motionvec_t;
var
  cur_partition: pbyte;
  mbcmp: mbcmp_func_t;
  max_x, max_y: integer;
  mbx, mby,              //macroblock qpel x,y position
  x, y: integer;         //currently searched qpel x,y position
  min_score: integer;
  mv,
  mv_prev_pass: motionvec_t;
  range: integer;
  iter: integer;
  check_bounds: boolean;

function chroma_score: integer; inline;
begin
  result := dsp.satd_8x4(mb.pixels_c[0], mb.mcomp_c[0], 16);
  result += dsp.satd_8x4(mb.pixels_c[1], mb.mcomp_c[1], 16);
end;

procedure check_pattern_qpel;
var
  i: integer;
  nx, ny,
  nx_partition, ny_partition: integer;
  score: integer;
begin
  if check_bounds then
      if (x - 1 < MIN_XY_QPEL) or (x + 1 > max_x) or
         (y - 1 < MIN_XY_QPEL) or (y + 1 > max_y) then exit;
  for i := 0 to 3 do begin
      nx := x + pt_dia_small[i][0];
      ny := y + pt_dia_small[i][1];
      nx_partition := nx + XY_qpel_offset_16x8[idx, 0];
      ny_partition := ny + XY_qpel_offset_16x8[idx, 1];

      //offset to current sub-block
      MotionCompensation.CompensateQPelXY_16x8(fref, nx_partition, ny_partition, mb.mcomp);
      score := mbcmp(cur_partition, mb.mcomp, 16)
               + InterCost.Bits(XYToMVec(nx - mbx, ny - mby));

      if chroma_me then begin
          MotionCompensation.CompensateChromaQpelXY_8x4(fref, nx_partition, ny_partition, mb.mcomp_c[0], mb.mcomp_c[1]);
          score += chroma_score();
      end;

      if score < min_score then begin
          min_score := score;
          mv := XYToMVec(nx - mbx, ny - mby);
      end;
  end;
  x := mbx + mv.x;
  y := mby + mv.y;
end;

begin
  cur_partition := cur + MB_pixel_offset_16x8[idx, 0] + MB_pixel_offset_16x8[idx, 1] * 16;  //MB_STRIDE
  mbx    := _mbx * 4;
  mby    := _mby * 4;
  max_x  := _max_x_qpel;
  max_y  := _max_y_qpel;
  if satd then
      mbcmp := dsp.satd_16x8
  else
      mbcmp := dsp.satd_16x8;  //todo SAD
  range  := ME_RANGES[mpQpel]*2;

  mv := mb.mv;
  x := mbx + mv.x;
  y := mby + mv.y;

  min_score := MaxInt;  //reset score, mbcmp may be different

  iter := 0;
  check_bounds := (x - range < MIN_XY_QPEL) or (x + range > max_x) or
                  (y - range < MIN_XY_QPEL) or (y + range > max_y);
  repeat
      mv_prev_pass := mv;
      check_pattern_qpel();
      iter += 1;
  until (mv = mv_prev_pass) or (iter >= range);

  if min_score = MaxInt then begin    //return valid score if no searches were done (rare cases at the padded edge of a frame)
      x += XY_qpel_offset_16x8[idx, 0];
      y += XY_qpel_offset_16x8[idx, 1];
      MotionCompensation.CompensateQPelXY_16x8(fref, x, y, mb.mcomp);
      min_score := mbcmp(cur, mb.mcomp, 16) + InterCost.Bits(mv);
      if chroma_me then begin
          MotionCompensation.CompensateChromaQpelXY_8x4(fref, x, y, mb.mcomp_c[0], mb.mcomp_c[1]);
          min_score += chroma_score();
      end;
  end;

  _last_search_score := min_score;
  result := mv;
end;

end.

