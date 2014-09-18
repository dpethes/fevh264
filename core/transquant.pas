(*******************************************************************************
transquant.pas
Copyright (c) 2010 David Pethes

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

unit transquant;
{$mode objfpc}{$H+}


interface

procedure transqt (block: psmallint; const qp: byte; const intra: boolean; const quant_start_idx: byte = 0);
procedure itransqt(block: psmallint; const qp: byte; const quant_start_idx: byte = 0);

procedure transqt_dc_2x2 (block: psmallint; const qp: byte);
procedure itransqt_dc_2x2(block: psmallint; const qp: byte);

procedure transqt_dc_4x4 (block: psmallint; const qp: byte);
procedure itransqt_dc_4x4(block: psmallint; const qp: byte);

procedure itrans_dc  (block: psmallint);


(*******************************************************************************
*******************************************************************************)
implementation


const
table_qp_div6: array[0..51] of byte =
  (0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2,3,3,3,3,3,3,4,4,4,4,4,4,5,5,5,5,5,5,6,6,6,6,6,6,7,7,7,7,7,7,8,8,8,8);
table_qp_mod6: array[0..51] of byte =
  (0,1,2,3,4,5,0,1,2,3,4,5,0,1,2,3,4,5,0,1,2,3,4,5,0,1,2,3,4,5,0,1,2,3,4,5,0,1,2,3,4,5,0,1,2,3,4,5,0,1,2,3);

{ E matrix - scaling factors:
  a^2 = 1
  ab/2 = 2
  b^2/4 = 3
}
coef_idx: array[0..15] of byte = (
  1, 2, 1, 2,
  2, 3, 2, 3,
  1, 2, 1, 2,
  2, 3, 2, 3
);

//V = Qstep*PF*64 rescaling factor
//-> LevelScale (8-252)
table_v_coefs: array[0..5, 1..3] of byte = (
  (10, 13, 16), //0
  (11, 14, 18),
  (13, 16, 20),
  (14, 18, 23),
  (16, 20, 25),
  (18, 23, 29)  //5
);

//(PF/Qstep) mult. factor
//1, 2, 3
//-> LevelScale2 (8-293)
table_mf_coefs: array[0..5, 1..3] of smallint = (
  (13107, 8066, 5243), //0
  (11916, 7490, 4660),
  (10082, 6554, 4194),
  (9362,  5825, 3647),
  (8192,  5243, 3355),
  (7282,  4559, 2893)  //5
);


type
  matrix_t = array[0..3, 0..3] of smallint;
  dc_matrix_t = array[0..1, 0..1] of smallint;
  dc_matrix_p = ^dc_matrix_t;


var
  resc_factor,
  mult_factor: array[0..5, 0..15] of smallint;


procedure init_tables;
var
  i, j: byte;
begin
  for i := 0 to 5 do begin
      for j := 0 to 15 do begin
          mult_factor[i][j] := table_mf_coefs[i, coef_idx[j]];
          resc_factor[i][j] := table_v_coefs [i, coef_idx[j]];
      end;
  end;
end;


//Z = (|W| . MF + f) >> qbits
procedure quant(a: psmallint; const qp: byte; const intra: boolean; const sidx: byte);
var
  i: integer;
  f: integer;
  qbits: byte;
  mf: psmallint;
begin
  //multiply shift
  qbits := 15 + table_qp_div6[qp];
  //multiply factor
  mf := @mult_factor[ table_qp_mod6[qp] ];
  //rounding factor
  if intra then
      f := (1 shl qbits) div 3
  else
      f := (1 shl qbits) div 6;

  a  += sidx;
  mf += sidx;
  for i := sidx to 15 do begin
      if a^ > 0 then
          a^ := ( a^ * mf^ + f) shr qbits
      else
          a^ := - (( f - a^ * mf^ ) shr qbits);  //fix from x264
      a  += 1;
      mf += 1;
  end;
end;



procedure core_4x4(block: psmallint);
var
  m: matrix_t;
  e, f, g, h: array[0..3] of smallint;
  i: integer;
begin
  move(block^, m, 16*2);

  { aaaa
    bbbb
    cccc
    dddd
  }
  for i := 0 to 3 do begin
      e[i] := m[0][i] + m[3][i];  //a + d
      f[i] := m[0][i] - m[3][i];  //a - d
      g[i] := m[1][i] + m[2][i];  //b + c
      h[i] := m[1][i] - m[2][i];  //b - c
  end;

  for i := 0 to 3 do begin
      m[0][i] :=     e[i] + g[i];     // a + b +  c +  d
      m[1][i] := 2 * f[i] + h[i];     //2a + b -  c - 2d
      m[2][i] :=     e[i] - g[i];     // a - b -  c +  d
      m[3][i] :=     f[i] - h[i] * 2; // a -2b + 2c -  d
  end;

  { abcd
    abcd
    abcd
    abcd
  }
  for i := 0 to 3 do begin
      e[i] := m[i][0] + m[i][3];
      f[i] := m[i][0] - m[i][3];
      g[i] := m[i][1] + m[i][2];
      h[i] := m[i][1] - m[i][2];
  end;

  for i := 0 to 3 do begin
      m[i][0] :=     e[i] + g[i];
      m[i][1] := 2 * f[i] + h[i];
      m[i][2] :=     e[i] - g[i];
      m[i][3] :=     f[i] - h[i] * 2;
  end;

  move(m, block^, 16*2);
end;


procedure transqt(block: psmallint; const qp: byte; const intra: boolean; const quant_start_idx: byte);
begin
  core_4x4(block);
  quant(block, qp, intra, quant_start_idx);
end;



(*******************************************************************************
iHCT + dequant
*)
procedure iquant(a: psmallint; const qp: byte; const sidx: byte);
var
  i: integer;
  shift: integer;
  mf: psmallint;
begin
  shift := table_qp_div6[qp];
  mf := @resc_factor[ table_qp_mod6[qp] ];
  a  += sidx;
  mf += sidx;
  for i := sidx to 15 do begin
      a^ := a^ * mf^ shl shift;
      a  += 1;
      mf += 1;
  end;
end;


procedure icore_4x4(block: psmallint);
var
  m: matrix_t;
  e, f, g, h: array[0..3] of smallint;
  i: integer;
begin
  move(block^, m, 16*2);

  for i := 0 to 3 do begin
      e[i] := m[i][0] + m[i][2];
      f[i] := m[i][0] - m[i][2];
      g[i] := m[i][1] + SarSmallint(m[i][3]);
      h[i] := SarSmallint(m[i][1]) - m[i][3];
  end;
  for i := 0 to 3 do begin
      m[i][0] := e[i] + g[i];
      m[i][1] := f[i] + h[i];
      m[i][2] := f[i] - h[i];
      m[i][3] := e[i] - g[i];
  end;

  for i := 0 to 3 do begin
      e[i] := m[0][i] + m[2][i];
      f[i] := m[0][i] - m[2][i];
      g[i] := m[1][i] + SarSmallint(m[3][i]);
      h[i] := SarSmallint(m[1][i]) - m[3][i];
  end;
  for i := 0 to 3 do begin
      m[0][i] := SarSmallint( e[i] + g[i] + 32, 6 );  //rescaling
      m[1][i] := SarSmallint( f[i] + h[i] + 32, 6 );
      m[2][i] := SarSmallint( f[i] - h[i] + 32, 6 );
      m[3][i] := SarSmallint( e[i] - g[i] + 32, 6 );
  end;

  move(m, block^, 16*2);
end;


procedure itransqt(block: psmallint; const qp: byte; const quant_start_idx: byte = 0);
begin
  iquant(block, qp, quant_start_idx);
  icore_4x4(block);
end;



(*******************************************************************************
chroma DC
*)
procedure trans_dc_2x2(block: psmallint);
var
  m: dc_matrix_t;
  e, f, g, h: integer;
begin
  m := dc_matrix_p( block )^;
  e := m[0, 0] + m[1, 0];
  f := m[0, 0] - m[1, 0];
  g := m[0, 1] + m[1, 1];
  h := m[0, 1] - m[1, 1];
  m[0, 0] := e + g;
  m[0, 1] := e - g;
  m[1, 0] := f + h;
  m[1, 1] := f - h;
  dc_matrix_p( block )^ := m;
end;


procedure quant_dc_2x2(a: psmallint; const qp: byte);
var
  i: integer;
  f: integer;
  qbits: byte;
  mf: smallint;
begin
  //multiply factor
  mf := mult_factor[table_qp_mod6[qp], 0];
  //multiply shift
  qbits := 16 + table_qp_div6[qp];
  f := 1 shl (qbits - 1);

  for i := 0 to 3 do
      if a[i] > 0 then
          a[i] := ( a[i] * mf + f) shr qbits
      else
          a[i] := - (( f - a[i] * mf ) shr qbits);
end;


procedure iquant_dc_2x2(a: psmallint; const qp: byte);
var
  i: integer;
  shift: integer;
  mf: smallint;
begin
  shift := table_qp_div6[qp] - 1;
  mf := resc_factor[table_qp_mod6[qp], 0];
  if qp >= 6 then begin
      for i := 0 to 3 do
          a[i] := a[i] * mf shl shift;
  end else
      for i := 0 to 3 do
          a[i] := SarSmallint( a[i] * mf );
end;


procedure transqt_dc_2x2(block: psmallint; const qp: byte);
begin
  trans_dc_2x2(block);
  quant_dc_2x2(block, qp);
end;


procedure itransqt_dc_2x2(block: psmallint; const qp: byte);
begin
  trans_dc_2x2(block);
  iquant_dc_2x2(block, qp);
end;


procedure itrans_dc (block: psmallint);
var
  dc: smallint;
  i: integer;
begin
  dc := SarSmallint(block[0] + 32, 6);
  for i := 0 to 15 do
      block[i] := dc;
end;



(*******************************************************************************
luma DC 4x4
*)
procedure core_4x4_dc(block: psmallint);
var
  m: matrix_t;
  e, f, g, h: array[0..3] of smallint;
  i: integer;
begin
  move(block^, m, 16*2);

  for i := 0 to 3 do begin
      e[i] := m[0][i] + m[3][i];  //a + d
      f[i] := m[0][i] - m[3][i];  //a - d
      g[i] := m[1][i] + m[2][i];  //b + c
      h[i] := m[1][i] - m[2][i];  //b - c
  end;

  for i := 0 to 3 do begin
      m[0][i] := e[i] + g[i];  // a + b + c + d
      m[1][i] := f[i] + h[i];  // a + b - c - d
      m[2][i] := e[i] - g[i];  // a - b - c + d
      m[3][i] := f[i] - h[i];  // a - b + c - d
  end;

  for i := 0 to 3 do begin
      e[i] := m[i][0] + m[i][3];
      f[i] := m[i][0] - m[i][3];
      g[i] := m[i][1] + m[i][2];
      h[i] := m[i][1] - m[i][2];
  end;

  for i := 0 to 3 do begin
      m[i][0] := e[i] + g[i];
      m[i][1] := f[i] + h[i];
      m[i][2] := e[i] - g[i];
      m[i][3] := f[i] - h[i];
  end;

  move(m, block^, 16*2);
end;


procedure quant_dc_4x4(a: psmallint; const qp: byte);
var
  i: integer;
  f: integer;
  qbits: byte;
  mf: psmallint;
begin
  //scale by 2
  for i := 0 to 15 do
      if a[i] > 0 then
          a[i] := (a[i] + 1) div 2
      else
          a[i] := (a[i] - 1) div 2;

  //multiply factor
  mf := @mult_factor[ table_qp_mod6[qp] ];
  //multiply shift
  qbits := 16 + table_qp_div6[qp];
  f := 1 shl (qbits - 1);

  for i := 0 to 15 do
      if a[i] > 0 then
          a[i] := ( a[i] * mf[0] + f) shr qbits
      else
          a[i] := - (( f - a[i] * mf[0] ) shr qbits);
end;


procedure iquant_dc_4x4(a: psmallint; const qp: byte);
var
  i: integer;
  f, shift: integer;
  mf: integer;
begin
  mf := resc_factor[table_qp_mod6[qp], 0];

  if qp >= 12 then begin
      shift := table_qp_div6[qp] - 2;
      for i := 0 to 15 do
          a[i] := a[i] * mf shl shift;
  end else begin
      shift := 2 - table_qp_div6[qp];
      f := 1 shl (1 - table_qp_div6[qp]);
      for i := 0 to 15 do
          a[i] := SarSmallint(a[i] * mf + f, shift);
  end;
end;


procedure transqt_dc_4x4(block: psmallint; const qp: byte);
begin
  core_4x4_dc(block);
  quant_dc_4x4(block, qp);
end;


procedure itransqt_dc_4x4(block: psmallint; const qp: byte);
begin
  core_4x4_dc  (block);
  iquant_dc_4x4(block, qp);
end;


(*******************************************************************************
*******************************************************************************)
initialization
init_tables;

end.

