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
  common, util;

procedure CalculateBStrength (const mb: macroblock_p);
procedure DeblockMBRow(
  const mby: integer;
  const f: frame_t;
  const cqp: boolean = true;
  const offset_a: integer = 0; const offset_b: integer = 0);

(*******************************************************************************
*******************************************************************************)
implementation

const
//Table 8-14 – Derivation of indexA and indexB from offset dependent threshold variables α and β
TAB_ALPHA: array[0..QP_MAX] of byte = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4,4,5,6,7,8,9,10,12,13,
           15,17,20,22,25,28,32,36,40,45,50,56,63,71,80,90,101,113,127,144,162,182,203,226,255,255);
TAB_BETA: array[0..QP_MAX] of byte = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,2,2,3,3,3,3,4,4,4,
          6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13,14,14,15,15,16,16,17,17,18,18);

//Table 8-15 – Value of filter clipping variable tC0 as a function of indexA and bS
TAB_TC0: array[1..3, 0..QP_MAX] of byte = (
  (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,
   1,1,1,1,1,1,1,2,2,2,2,3,3,3,4,4,4,5,6,6,7,8,9,10,11,13),
  (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,
   1,1,1,1,1,2,2,2,2,3,3,3,4,4,5,5,6,7,8,8,10,11,12,13,15,17),
  (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,
   1,2,2,2,2,3,3,3,4,4,4,5,6,6,7,8,9,10,11,13,14,16,18,20,23,25)
);

BLOCK_XY_POS_TO_IDX: array[0..3, 0..3] of byte = (
  ( 0,  2,  8, 10),
  ( 1,  3,  9, 11),
  ( 4,  6, 12, 14),
  ( 5,  7, 13, 15)
);

function clip(i: integer): byte; inline;
begin
  if word(i) > 255 then result := byte(not(i >> 16))
  else result := byte(i);
end;


{ 8.7.2.1 Derivation process for the luma content dependent boundary filtering strength
mixedModeEdgeFlag = 0 (prog)
}
procedure CalculateBStrength (const mb: macroblock_p);

  //filtering strength between blocks of the same macroblock
  function inner_edge_bS(const a: macroblock_p; na, nb: integer): integer; inline;
  begin
    //a^.nz_coef_cnt[na] + a^.nz_coef_cnt[nb] > 0  ?  2 : 0
    result := (((a^.nz_coef_cnt[na] + a^.nz_coef_cnt[nb]) * $ffff) >> 8) and 2;
  end;

  //filtering strength between blocks of two different macroblocks
  function outer_edge_bS(const a, b: macroblock_p; na, nb: integer; bS_min: integer): integer; inline;
  const
    CLIP_TABLE: array[0..3] of byte = (0, 1, 2, 2);
  begin
    //a^.nz_coef_cnt[na] + b^.nz_coef_cnt[nb] > 0  ?  2 : (0..1)
    result := CLIP_TABLE[((((a^.nz_coef_cnt[na] + b^.nz_coef_cnt[nb]) * $ffff) >> 8) and 2) + bS_min];
  end;

  //set strength=1 if mv delta >= 4
  function bS_by_mvdiff(const a, b: motionvec_t): integer; inline;
  begin
    //( abs(a.x - b.x) >= 4 ) or ( abs(a.y - b.y) >= 4 )  ?  1 : 0
    result := ((((abs(a.x - b.x) >> 2) + (abs(a.y - b.y) >> 2) ) * $ffff) >> 15) and 1;
  end;

  //MB_P_16x16, MB_P_SKIP only
  function mbtypes_with_single_mv(const a, b: macroblock_p): boolean; inline;
  begin
    result := ((a^.mbtype <= MB_P_SKIP) and (b^.mbtype <= MB_P_SKIP))
  end;

  function is_bS_sum_zero(pv, ph: pint64): boolean; inline;
  begin
    result := pv^ + (pv+1)^ + ph^ + (ph+1)^ = 0;
  end;

const
  intra_bS: TBSarray = ( (4,4,4,4), (3,3,3,3), (3,3,3,3), (3,3,3,3) );
  SHUFFLE4X = $01010101;

var
  i: integer;
  other_mb: macroblock_p;
  bS_min: array[0..3] of byte;
  bS_min_overall: uint32 absolute bS_min;

begin
  if is_intra(mb^.mbtype) then begin
      mb^.bS_vertical   := intra_bS;
      mb^.bS_horizontal := intra_bS;
      mb^.bS_zero := false;
      exit;
  end;

  { internal edges - strength depends on current mb's luma coef count and partition mvs
    Assume no partitions first, then correct partition edges by mv diff condition if needed
  }
  if (mb^.cbp and CBP_LUMA_MASK) > 0 then begin
      for i := 1 to 3 do begin
          mb^.bS_vertical  [i, 0] := inner_edge_bS(mb, BLOCK_XY_POS_TO_IDX[i, 0], BLOCK_XY_POS_TO_IDX[i-1, 0]);
          mb^.bS_vertical  [i, 1] := inner_edge_bS(mb, BLOCK_XY_POS_TO_IDX[i, 1], BLOCK_XY_POS_TO_IDX[i-1, 1]);
          mb^.bS_vertical  [i, 2] := inner_edge_bS(mb, BLOCK_XY_POS_TO_IDX[i, 2], BLOCK_XY_POS_TO_IDX[i-1, 2]);
          mb^.bS_vertical  [i, 3] := inner_edge_bS(mb, BLOCK_XY_POS_TO_IDX[i, 3], BLOCK_XY_POS_TO_IDX[i-1, 3]);

          mb^.bS_horizontal[i, 0] := inner_edge_bS(mb, BLOCK_XY_POS_TO_IDX[0, i], BLOCK_XY_POS_TO_IDX[0, i-1]);
          mb^.bS_horizontal[i, 1] := inner_edge_bS(mb, BLOCK_XY_POS_TO_IDX[1, i], BLOCK_XY_POS_TO_IDX[1, i-1]);
          mb^.bS_horizontal[i, 2] := inner_edge_bS(mb, BLOCK_XY_POS_TO_IDX[2, i], BLOCK_XY_POS_TO_IDX[2, i-1]);
          mb^.bS_horizontal[i, 3] := inner_edge_bS(mb, BLOCK_XY_POS_TO_IDX[3, i], BLOCK_XY_POS_TO_IDX[3, i-1]);
      end;
  end;
  if mb^.mbtype = MB_P_16x8 then begin
      bS_min_overall := bS_by_mvdiff(mb^.mv, mb^.mv1);
      if bS_min_overall > 0 then
          for i := 0 to 3 do
              if mb^.bS_horizontal[2, i] = 0 then mb^.bS_horizontal[2, i] := 1;
  end;

  //vertical edges - 'left' macroblock edge
  if mb^.x > 0 then begin
      other_mb := mb^.mba;
      if is_intra(other_mb^.mbtype) then begin  //edge shared with intra block
          mb^.bS_vertical[0] := intra_bS[0];
      end
      else begin
          bS_min_overall := 0;
          if (mb^.ref <> other_mb^.ref) then
              bS_min_overall := 1 * SHUFFLE4X
          else if mbtypes_with_single_mv(mb, other_mb) then
              bS_min_overall := bS_by_mvdiff(mb^.mv, other_mb^.mv) * SHUFFLE4X
          else begin
              //eval mvdiff per block - only handles MB_P_16x8 for now
              bS_min[0] := bS_by_mvdiff(mb^.mv,  other_mb^.mv);
              bS_min[1] := bS_min[0];
              bS_min[2] := bS_by_mvdiff(mb^.mv1, other_mb^.mv1);
              bS_min[3] := bS_min[2];
          end;
          mb^.bS_vertical[0, 0] := outer_edge_bS(mb, other_mb, 0,  5, bS_min[0]);
          mb^.bS_vertical[0, 1] := outer_edge_bS(mb, other_mb, 2,  7, bS_min[1]);
          mb^.bS_vertical[0, 2] := outer_edge_bS(mb, other_mb, 8, 13, bS_min[2]);
          mb^.bS_vertical[0, 3] := outer_edge_bS(mb, other_mb,10, 15, bS_min[3]);
      end;
  end;

  //horizontal edges - 'top' macroblock edge
  if mb^.y > 0 then begin
      other_mb := mb^.mbb;
      if is_intra(other_mb^.mbtype) then begin  //edge shared with intra block
          mb^.bS_horizontal[0] := intra_bS[0];
      end
      else begin
          bS_min_overall := 0;
          if (mb^.ref <> other_mb^.ref) then
              bS_min_overall := 1 * SHUFFLE4X
          else if mbtypes_with_single_mv(mb, other_mb) then
              bS_min_overall := bS_by_mvdiff(mb^.mv, other_mb^.mv) * SHUFFLE4X
          else begin
              //eval mvdiff per block - only handles MB_P_16x8 for now
              bS_min_overall := bS_by_mvdiff(mb^.mv, other_mb^.mv1) * SHUFFLE4X;
          end;
          mb^.bS_horizontal[0, 0] := outer_edge_bS(mb, other_mb, 0, 10, bS_min[0]);
          mb^.bS_horizontal[0, 1] := outer_edge_bS(mb, other_mb, 1, 11, bS_min[1]);
          mb^.bS_horizontal[0, 2] := outer_edge_bS(mb, other_mb, 4, 14, bS_min[2]);
          mb^.bS_horizontal[0, 3] := outer_edge_bS(mb, other_mb, 5, 15, bS_min[3]);
      end;
  end;

  mb^.bS_zero := is_bS_sum_zero(@mb^.bS_vertical, @mb^.bS_horizontal);
end;



procedure DeblockMBRow(
  const mby: integer;
  const f: frame_t;
  const cqp: boolean = true;
  const offset_a: integer = 0; const offset_b: integer = 0);
var
  p, q: array[0..3] of int16;
  bS_vertical, bS_horizontal: TBSarray;
  edge_start_idx_vert,
  edge_start_idx_horiz: integer;

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
  result := (Abs( p[1] - p[0] ) < beta) and (Abs( q[1] - q[0] ) < beta) and (Abs( p[0] - q[0] ) < alpha)
end;

procedure FilterLuma16x16(const pixel: pbyte; const indexA, alpha, beta: integer);
var
  edge, blk, samples: integer;
  i: integer;
  bs: integer;
  pix: pbyte;
  stride: integer;
  bstrengths: array[0..3] of byte;
begin
  stride := f.stride;

  //vertical
  for edge := edge_start_idx_vert to 3 do begin
      pix := pixel + edge * 4;
      bstrengths := bS_vertical[edge];
      if pinteger(@bstrengths)^ = 0 then
          continue;

      for blk := 0 to 3 do begin
          bs := bstrengths[blk];
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

  //horizontal
  for edge := edge_start_idx_horiz to 3 do begin
      pix := pixel + edge * 4 * stride;
      bstrengths := bS_horizontal[edge];
      if pinteger(@bstrengths)^ = 0 then
        continue;

      for blk := 0 to 3 do begin
          bs := bstrengths[blk];
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

              pix += 1;  //next pixel column
          end;
      end;
  end;
end;


procedure FilterChroma8x8(const pixel: pbyte; const indexA_c, alpha_c, beta_c: integer);
var
  edge: integer;
  i, k: integer;
  bs: integer;
  pix: pbyte;
  stride: integer;
  bstrengths: array[0..3] of byte;
begin
  stride := f.stride_c;

  for edge := edge_start_idx_vert to 1 do begin
      bstrengths := bS_vertical[edge];
      if pinteger(@bstrengths)^ = 0 then
          continue;

      pix := pixel + edge * 4;
      for k := 0 to 7 do begin
          bs := bstrengths[k >> 1];
          if (bs > 0) then begin
              for i := 0 to 1 do q[i] := pix[     i];
              for i := 0 to 1 do p[i] := pix[-(i+1)];

              if UseFilter(alpha_c, beta_c) then begin
                  FilterSamplesChroma(bs, indexA_c);
                  pix[-1] := p[0];
                  pix[ 0] := q[0];
              end;
          end;
          pix += stride;  //next pixel row
      end;
  end;

  for edge := edge_start_idx_horiz to 1 do begin
      bstrengths := bS_horizontal[edge];
      if pinteger(@bstrengths)^ = 0 then
          continue;

      pix := pixel + edge * 4 * stride;
      for k := 0 to 7 do begin
          bs := bstrengths[k >> 1];
          if (bs > 0) then begin
              for i := 0 to 1 do q[i] := pix[     i * stride];
              for i := 0 to 1 do p[i] := pix[-(i+1) * stride];

              if UseFilter(alpha_c, beta_c) then begin
                  FilterSamplesChroma(bs, indexA_c);
                  pix[      0] := q[0];
                  pix[-stride] := p[0];
              end;
          end;
          pix += 1;  //next pixel column
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
  qpa, qpc: integer;
  indexB, indexB_c: integer;
begin
  qpa := mb^.qp;  //simplified for cqp with no I_PCM
  indexA := clip3(0, qpa + offset_a, QP_MAX);
  indexB := clip3(0, qpa + offset_b, QP_MAX);
  alpha := TAB_ALPHA[indexA];
  beta  := TAB_BETA [indexB];

  if qpa < 30 then begin
      indexA_c := indexA;
      alpha_c := alpha;
      beta_c  := beta;
  end else begin
      qpc := mb^.qpc;
      indexA_c := clip3(0, qpc + offset_a, QP_MAX);
      indexB_c := clip3(0, qpc + offset_b, QP_MAX);
      alpha_c := TAB_ALPHA[indexA_c];
      beta_c  := TAB_BETA [indexB_c];
  end;
end;

procedure FilterMB(const mb: macroblock_p);
begin
  bS_vertical   := mb^.bS_vertical;
  bS_horizontal := mb^.bS_horizontal;
  FilterLuma16x16   (mb^.pfdec,      indexA,   alpha,   beta);
  FilterChroma8x8   (mb^.pfdec_c[0], indexA_c, alpha_c, beta_c);
  FilterChroma8x8   (mb^.pfdec_c[1], indexA_c, alpha_c, beta_c);
end;

var
  mb: macroblock_p;

begin
  { limit A/B offset even if spec allows 2x more to avoid filtering on QP<10, when I_PCM can be present,
    because the simplified setup can't handle it. For I_PCM and for adapt QP, the QPz is decided by averaging
    with surrounding MBs
  }
  Assert((abs(offset_a) <= 6) and (abs(offset_b) <= 6));

  edge_start_idx_horiz := 0;
  if mby = 0 then
      edge_start_idx_horiz := 1;
  edge_start_idx_vert := 1;
  mb := @f.mbs[mby * f.mbw];

  if cqp then begin
      SetupParams(mb);  //filter params depend on qp
      for mbx := 0 to f.mbw - 1 do begin
          if not mb^.bS_zero then begin
              FilterMB(mb);
          end;
          mb += 1;
          edge_start_idx_vert := 0;
      end;
  end else begin
      for mbx := 0 to f.mbw - 1 do begin
          if not mb^.bS_zero then begin
              SetupParams(mb);
              FilterMB(mb);
          end;
          mb += 1;
          edge_start_idx_vert := 0;
      end;
  end;
end;


end.

