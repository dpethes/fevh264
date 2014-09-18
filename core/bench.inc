(*
bench.inc - translation of FFmpeg's START_TIMER / STOP_TIMER macros 
Copyright (c) 2007 David Pethes

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
along with EVK.  If not, see <http://www.gnu.org/licenses/>.

*)
(* copyright of original macros, from ffmpeg\libavutil\common.h
 *
 * copyright (c) 2006 Michael Niedermayer <michaelni@gmx.at>
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 *
*)
(*
This code was taken from FFmpeg project and modified for use in Fev.
Thanks to Michael Niedermayer.
*)

var
  tend,
  tstart: Int64;
  tsum: int64 = 0;
  tcount: integer = 0;
  tskip_count: integer = 0;

function max(a, b: integer): integer; inline;
begin
  if a > b then max := a
  else          max := b;
end;

{$asmmode intel}
function rdtsc: Int64; assembler; register; nostackframe;
asm
  rdtsc
end;

procedure start_timer; inline;
begin
  tstart := rdtsc;
end;

procedure stop_timer(const id: pchar); inline;
begin
  tend := rdtsc;
  if ( (tcount < 2) or ((tend - tstart) < max( 8 * tsum div tcount, 2000) ) ) and (tend > tstart) then begin
      tsum += tend - tstart;
      tcount += 1;
  end else
      tskip_count += 1;
  if ( (tcount + tskip_count) and (tcount + tskip_count - 1) ) = 0 then
      writeln( stderr, tsum * 10 div tcount, ' dezicycles in ', id, ', ', tcount, ' runs, ', tskip_count, ' skips');
end;  
