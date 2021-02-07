(*******************************************************************************
frame.pas
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

unit frame;
{$mode objfpc}{$H+}

interface

uses
  sysutils, stats, common, image, pixel, util;

const
  FRAME_PADDING_W = 16;
  FRAME_EDGE_W = FRAME_PADDING_W div 2;

procedure frame_new(var frame: frame_t; const mb_width, mb_height: integer);
procedure frame_free(var frame: frame_t);
procedure frame_decoded_macroblock_row_ssd(frame: frame_p; const mby: integer);
procedure frame_write_stats (var stats_file: textfile; const frame: frame_t);
procedure frame_img2frame_copy(var frame: frame_t; const img: TPlanarImage);
procedure frame_paint_edges(var frame: frame_t);
procedure frame_hpel_interpolate(var frame: frame_t);
procedure frame_lowres_from_input(var frame: frame_t);
procedure frame_lowres_from_decoded(var frame: frame_t);

type

  { TFrameManager }

  TFrameManager = class
    private
      listL0: array of frame_t;
      ifree: integer;
      procedure GetRef(out f: frame_p; const frame_num: integer);
    public
      lowres_mb_width,
      lowres_mb_height: integer;

      procedure InsertRef(var f: frame_t);
      procedure SetRefs(var f: frame_t; const frame_num, nrefs: integer);
      procedure GetFree(var f: frame_t);
      procedure debug;
      constructor Create(const ref_count, mb_w, mb_h: integer);
      destructor Free;
  end;

procedure frame_init(const flags: TDsp_init_flags);

(*******************************************************************************
*******************************************************************************)
implementation

procedure frame_new(var frame: frame_t; const mb_width, mb_height: integer);
var
  padded_height, padded_width,
  frame_mem_offset, frame_mem_offset_cr: integer; //frame memory to image data start offset
  pfsize, pfsize_cr: integer;                     //padded frame luma / chroma plane size
  i: integer;
begin
  with frame do begin
      mbw  := mb_width;
      mbh  := mb_height;
      w    := mbw * 16;
      h    := mbh * 16;
      padded_width  := w + FRAME_PADDING_W * 2;
      padded_height := h + FRAME_PADDING_W * 2;
  end;

  frame.pw := padded_width;
  frame.ph := padded_height;
  frame.stride   := padded_width;
  frame.stride_c := padded_width div 2;

  pfsize := padded_width * padded_height;
  pfsize_cr := pfsize div 4;
  frame_mem_offset    := FRAME_PADDING_W * padded_width + FRAME_PADDING_W;
  frame_mem_offset_cr := FRAME_PADDING_W * padded_width div 4 + FRAME_PADDING_W div 2;

  frame.mbs := fev_malloc( mb_width * mb_height * sizeof(macroblock_t) );
  frame.aq_table := fev_malloc( mb_width * mb_height );
  frame.qp := 0;
  frame.qp_avg := 0;
  frame.num := 0;

  frame.frame_mem_offset := frame_mem_offset;
  frame.frame_mem_offset_cr := frame_mem_offset_cr;

  //luma plane
  frame.mem[0] := fev_malloc( pfsize + pfsize_cr * 2 );
  frame.plane[0] := frame.mem[0] + frame_mem_offset;
  //chroma planes
  frame.mem[1] := frame.mem[0] + pfsize;
  frame.mem[2] := frame.mem[1] + pfsize_cr;
  frame.plane[1] := frame.mem[1] + frame_mem_offset_cr;
  frame.plane[2] := frame.mem[2] + frame_mem_offset_cr;
  //decoded planes + interpolated planes
  frame.mem[3] := fev_malloc( pfsize * 4 + pfsize_cr * 2 );
  frame.plane_dec[0] := frame.mem[3] + frame_mem_offset;
  for i := 0 to 3 do
      frame.luma_mc[i] := frame.plane_dec[0] + pfsize * i;
  for i := 0 to 3 do
      frame.luma_mc_qpel[i] := frame.luma_mc[i];
  frame.luma_mc_qpel[4] := frame.luma_mc[0] + 1;
  frame.luma_mc_qpel[5] := frame.luma_mc[2] + 1;
  frame.luma_mc_qpel[6] := frame.luma_mc[0] + padded_width;
  frame.luma_mc_qpel[7] := frame.luma_mc[1] + padded_width;

  frame.mem[4] := frame.mem[3] + pfsize * 4;
  frame.mem[5] := frame.mem[4] + pfsize_cr;
  frame.plane_dec[1] := frame.mem[4] + frame_mem_offset_cr;
  frame.plane_dec[2] := frame.mem[5] + frame_mem_offset_cr;

  //4x4 block offsets
  with frame do begin
      blk_offset[ 0] := 0;
      blk_offset[ 1] := 4;
      blk_offset[ 2] := 0 + 4 * stride;
      blk_offset[ 3] := 4 + 4 * stride;

      blk_offset[ 4] :=  8;
      blk_offset[ 5] := 12;
      blk_offset[ 6] :=  8 + 4 * stride;
      blk_offset[ 7] := 12 + 4 * stride;

      blk_offset[ 8] := 0 +  8 * stride;
      blk_offset[ 9] := 4 +  8 * stride;
      blk_offset[10] := 0 + 12 * stride;
      blk_offset[11] := 4 + 12 * stride;

      blk_offset[12] :=  8 +  8 * stride;
      blk_offset[13] := 12 +  8 * stride;
      blk_offset[14] :=  8 + 12 * stride;
      blk_offset[15] := 12 + 12 * stride;
  end;

  //other
  frame.filter_hv_temp := fev_malloc( padded_width * 2 );
  frame.bs_buf := fev_malloc(frame.w * frame.h * 3);
  frame.lowres := nil;

  frame.stats := TFrameStats.Create;
end;


procedure frame_free(var frame: frame_t);
begin
  fev_free(frame.mbs);
  fev_free(frame.aq_table);
  fev_free(frame.mem[0]);
  fev_free(frame.mem[3]);
  fev_free(frame.filter_hv_temp);
  fev_free(frame.bs_buf);
  frame.stats.Free;

  frame.plane[0] := nil;
  frame.plane[1] := nil;
  frame.plane[2] := nil;
  frame.filter_hv_temp := nil;

  frame.stride := 0;
  frame.stride_c := 0;

  frame.w := 0;
  frame.h := 0;
end;


procedure frame_swap(var a, b: frame_t);
var
  t: frame_t;
begin
  t := a;
  a := b;
  b := t;
end;


procedure frame_decoded_macroblock_row_ssd(frame: frame_p; const mby: integer);
var
  x, mb_width: integer;
  mb: macroblock_p;
  pixels: pbyte;
  pixels_c: array[0..1] of pbyte;
  pixelbuf: array[0..256+64*2+15] of byte;
begin
  mb_width := frame^.mbw;
  pixels := Align(@pixelbuf[0], 16);
  pixels_c[0] := pixels + 256;
  pixels_c[1] := pixels + 256 + 8;
  for x := 0 to (mb_width - 1) do begin
      mb := @(frame^.mbs[mby * mb_width + x]);
      dsp.pixel_load_16x16(pixels,      mb^.pfdec,      frame^.stride);
      dsp.pixel_load_8x8  (pixels_c[0], mb^.pfdec_c[0], frame^.stride_c);
      dsp.pixel_load_8x8  (pixels_c[1], mb^.pfdec_c[1], frame^.stride_c);

      frame^.stats.ssd[0] += dsp.ssd_16x16(pixels,      mb^.pfenc,      frame^.stride);
      frame^.stats.ssd[1] += dsp.ssd_8x8  (pixels_c[0], mb^.pfenc_c[0], frame^.stride_c);
      frame^.stats.ssd[2] += dsp.ssd_8x8  (pixels_c[1], mb^.pfenc_c[1], frame^.stride_c);
  end;
end;


procedure frame_write_stats (var stats_file: textfile; const frame: frame_t);
var
  ftype: char;
begin
  dsp.FpuReset;
  ftype := 'P';
  if frame.ftype = SLICE_I then begin
      ftype := 'I';
      //if not frame.idr then
      //    ftype := 'i';
  end;
  with frame.stats do
  writeln( stats_file,
    format('%4d %s qp: %2d (%4.2f) size: %6d  itex: %6d  ptex: %6d  other: %4d  i:%d p:%d skip: %d est: %d qpa:%d',
           [frame.num, ftype, frame.qp, frame.qp_avg,
            size_bytes * 8,
            itex_bits, ptex_bits, size_bytes * 8 - (itex_bits + ptex_bits),
            mb_i4_count + mb_i16_count, mb_p_count, mb_skip_count,
            frame.estimated_framebits ,
            frame.qp_adj
           ]) );
{
  if h.aq then
      for y := 0 to (h.mb_height - 1) do begin
          for x := 0 to (h.mb_width - 1) do begin
              write( h.stats_file, frame.aq_table[y * h.mb_width + x]:3 );
          end;
          writeln( h.stats_file );
      end;
}
end;


(*******************************************************************************
frame_setup_adapt_q
adjust mb quant according to variance
*)
procedure frame_setup_adapt_q(var frame: frame_t; pixbuffer: pbyte; const base_qp: byte);
const
  QP_RANGE = 10;
  QP_MIN = 15;
  QP_MAX = 51;
  VAR_SHIFT = 14;

var
  x, y: integer;
  vari: integer;
  qp: integer;
  pfenc, pix: pbyte;
  stride, avg: integer;

begin
  stride := frame.mbw;
  pix := pixbuffer;

  //derive qp from variance
  avg := 0;
  for y := 0 to (frame.mbh - 1) do begin
      pfenc := frame.plane[0] + y * 16 * frame.stride;

      for x := 0 to (frame.mbw - 1) do begin
          pixel_load_16x16(pix, pfenc, frame.stride);
          vari := dsp.var_16x16(pix);
          pfenc += 16;
          qp := base_qp - QP_RANGE;
          qp := clip3(QP_MIN,  qp + min(vari shr VAR_SHIFT, QP_RANGE * 2),  QP_MAX);
          avg += qp;
          frame.aq_table[y * stride + x] := qp;
      end;
  end;

  frame.aq_table[0] := base_qp;
  dsp.FpuReset;
  frame.qp_avg := avg / (frame.mbw * frame.mbh);
end;



{ skopirovanie dat do zarovnanej oblasti pamate spolu s vyplnou na okrajoch
}
procedure paint_edge_vert(src, dst: pbyte; stride, h: integer; const edge_width: byte);
var
  i, j: integer;
begin
  for i := 0 to h - 1 do begin
      for j := 0 to edge_width - 1 do
          dst[j] := src^;
      dst += stride;
      src += stride;
  end;
end;

procedure paint_edge_horiz(src, dst: pbyte; stride: integer; const edge_width: byte);
var
  i: integer;
begin
  for i := 0 to edge_width - 1 do begin
      move(src^, dst^, stride);
      dst += stride;
  end;
end;


procedure frame_img2frame_copy(var frame: frame_t; const img: TPlanarImage);
var
  w, h, i, j: integer;
  dstride, sstride, edge_width, chroma_height: integer;
  s, d: pbyte;
begin
  w := img.Width;
  h := img.Height;
  //y
  dstride := frame.stride;
  sstride := img.stride;
  d := frame.plane[0];
  s := img.plane[0];
  for i := 0 to h - 1 do begin
      move(s^, d^, w);
      s += sstride;
      d += dstride;
  end;
  //u/v
  dstride := frame.stride_c;
  sstride := img.stride_c;
  for j := 1 to 2 do begin
      d := frame.plane[j];
      s := img.plane[j];
      for i := 0 to h div 2 - 1 do begin
          move(s^, d^, w div 2);
          s += sstride;
          d += dstride;
      end;
  end;

  //fill non-mod16 edges
  if (w and $f) > 0 then begin
      edge_width := 16 - (img.Width and $f);
      paint_edge_vert(frame.plane[0] + w - 1, frame.plane[0] + w,
                      frame.stride, frame.h, edge_width);
      chroma_height := frame.h div 2;
      for i := 1 to 2 do
          paint_edge_vert(frame.plane[i] + w div 2 - 1, frame.plane[i] + w div 2,
                          frame.stride_c, chroma_height, edge_width div 2);
  end;
  if (h and $f) > 0 then begin
      edge_width := 16 - (img.Height and $f);
      paint_edge_horiz(frame.plane[0] - 16 + frame.stride * (h - 1),
                       frame.plane[0] - 16 + frame.stride * h, frame.stride, edge_width);
      for i := 1 to 2 do
          paint_edge_horiz(frame.plane[i] - 8 + frame.stride_c * (h div 2 - 1),
                           frame.plane[i] - 8 + frame.stride_c * h div 2, frame.stride_c, edge_width);
  end;
end;


(*******************************************************************************
fill plane edges with edge pixel's copies
*)
procedure plane_paint_edges(const p: pbyte; const w, h, stride, edge_width: integer);
begin
  //left/right/up/down
  paint_edge_vert (p,  p - edge_width, stride, h, edge_width);
  paint_edge_vert (p + w - 1, p + w, stride, h, edge_width);
  paint_edge_horiz(p - edge_width, (p - edge_width) - edge_width * stride, stride, edge_width);
  paint_edge_horiz(p - edge_width + stride * (h - 1), p - edge_width + stride * h, stride, edge_width);
end;

procedure frame_paint_edges(var frame: frame_t);
var
  i, chroma_width, chroma_height: integer;
begin
  plane_paint_edges(frame.plane_dec[0], frame.w, frame.h, frame.stride, 16);
  chroma_width := frame.w div 2;
  chroma_height := frame.h div 2;
  for i := 1 to 2 do
      plane_paint_edges(frame.plane_dec[i], chroma_width, chroma_height, frame.stride_c, 8);
end;


{ TFrameManager }

//insert ref. frame to oldest slot, mark oldest taken slot as free
procedure TFrameManager.InsertRef(var f: frame_t);
var
  i, oldest: integer;
begin
  //writeln('InsertRef: ', f.num);
  oldest := MaxInt;
  for i := 0 to Length(listL0) - 1 do
      if listL0[i].num < oldest then begin
          ifree := i;
          oldest := listL0[i].num;
      end;
  listL0[ifree] := f;
  //writeln('InsertRef slot: ', ifree);

  oldest := MaxInt;
  for i := 0 to Length(listL0) - 1 do
      if listL0[i].num < oldest then begin
          ifree := i;
          oldest := listL0[i].num;
      end;
end;

procedure TFrameManager.GetRef(out f: frame_p; const frame_num: integer);
var
  i: integer;
begin
  //writeln('getref: ', frame_num);
  for i := 0 to Length(listL0) - 1 do
      if listL0[i].num = frame_num then begin
          f := @listL0[i];
          exit;
      end;
  writeln('GetRef - ref not found! ', frame_num);
  halt;
end;

procedure TFrameManager.SetRefs(var f: frame_t; const frame_num, nrefs: integer);
var
  i: integer;
  t: frame_p;
begin
  for i := 1 to nrefs do begin
      GetRef(t, frame_num - i);
      f.refs[i-1] := t;
  end;
end;

procedure TFrameManager.GetFree(var f: frame_t);
begin
  if ifree = -1 then begin
      writeln('GetFree - no free frame!');
      halt;
  end;
  f := listL0[ifree];
  ifree := -1;
end;

procedure TFrameManager.debug;
var
  i: integer;
begin
  writeln('ifree: ', ifree);
  for i := 0 to Length(listL0) - 1 do begin
      writeln(i:3, listL0[i].num:4);
  end;
end;

constructor TFrameManager.Create(const ref_count, mb_w, mb_h: integer);
var
  i: integer;
begin
  ifree := 0;
  SetLength(listL0, ref_count + 1);

  lowres_mb_width  := (mb_w + 1) div 2;  //round mb count up
  lowres_mb_height := (mb_h + 1) div 2;

  for i := 0 to ref_count do begin
      frame_new( listL0[i], mb_w, mb_h );
      listL0[i].num := -1;

      listL0[i].lowres := fev_malloc(sizeof(frame_t));
      frame_new(listL0[i].lowres^, lowres_mb_width, lowres_mb_height);
  end;
end;

destructor TFrameManager.Free;
var
  i: integer;
begin
  for i := 0 to Length(listL0) - 1 do begin
      if listL0[i].lowres <> nil then begin
          frame_free(listL0[i].lowres^);
          fev_free(listL0[i].lowres);
      end;
      frame_free(listL0[i]);
  end;
  listL0 := nil;
end;


(*******************************************************************************
h.264 6tap hpel filter
*)
{$ifdef CPUI386}
{$define FILTER_ASM}
procedure filter_horiz_line_sse2 (src, dst: pbyte; width: integer); cdecl; external;
procedure filter_vert_line_sse2  (src, dst: pbyte; width, stride: integer; tmp: psmallint); cdecl; external;
procedure filter_hvtemp_line_sse2(src: psmallint; dst: pbyte; width: integer); cdecl; external;
{$endif}

{$ifdef CPUX86_64}
{$define FILTER_ASM}
procedure filter_horiz_line_sse2 (src, dst: pbyte; width: integer); external name 'filter_horiz_line_sse2';
procedure filter_vert_line_sse2  (src, dst: pbyte; width, stride: integer; tmp: psmallint); external name 'filter_vert_line_sse2';
procedure filter_hvtemp_line_sse2(src: psmallint; dst: pbyte; width: integer); external name 'filter_hvtemp_line_sse2';
{$endif}

var
  filter_use_asm: boolean;

//Call pascal or asm optimized version. Yes, it isn't very pretty
procedure frame_hpel_interpolate(var frame: frame_t);

procedure filter_normal();
var
  width, height: integer;
  stride: integer;
  src: pbyte;
  dst: array[0..2] of pbyte;
  row: array[-2..3] of pbyte;
  x, y, i, j: integer;
  t: array[-2..3] of integer;
  edge_offset: integer;

begin
  width  := frame.w;
  height := frame.h;
  stride := frame.stride;
  edge_offset := FRAME_EDGE_W + FRAME_EDGE_W * stride;
  src := frame.plane_dec[0] - edge_offset;
  for i := 0 to 2 do
      dst[i] := frame.luma_mc[i+1] - edge_offset;

  //horizontal
  for y := 0 to height - 1 + FRAME_EDGE_W * 2 do begin
      for x := 0 to width - 1 + FRAME_EDGE_W * 2 do begin
          i := src[-2+x] - 5*src[-1+x] + 20*src[0+x] + 20*src[1+x] - 5*src[2+x] + src[3+x] + 16;
          if i < 0 then i := 0;
          dst[0][x] := clip( i shr 5 );
      end;
      src += stride;
      dst[0] += stride;
  end;

  //vertical + hv
  src := frame.plane_dec[0] - edge_offset;
  for i := -2 to 3 do
      row[i] := src + i * stride;

  for y := 0 to height - 1 + FRAME_EDGE_W * 2 do begin
      //fill temps first
      x := -1;
      for j := x - 2 to x + 3 do
          t[j-x] := row[-2, j] -5*row[-1, j] + 20*row[0, j] + 20*row[1, j] -5*row[2, j] + row[3, j];

      for x := 0 to width - 1 + FRAME_EDGE_W * 2 do begin
          //reuse coefs from last run
          for j := -1 to 3 do
              t[j - 1] := t[j];
          //get new vertical intermed
          j := x + 3;
          t[3] := row[-2, j] -5*row[-1, j] + 20*row[0, j] + 20*row[1, j] -5*row[2, j] + row[3, j];
          //vert
          i := t[0] + 16;
          if i < 0 then i := 0;
          dst[1][y * stride + x] := clip( i shr 5 );
          //vert + horiz
          i := t[-2] - 5 * t[-1] + 20 * t[0] + 20 * t[1] - 5 * t[2] + t[3] + 512;
          if i < 0 then i := 0;
          dst[2][y * stride + x] := clip( i shr 10 );
      end;

      for i := -2 to 3 do
          row[i] += stride;
  end;
end;

{$ifdef FILTER_ASM}
procedure filter_asm(tmp: psmallint);
var
  width, height: integer;
  stride: integer;
  src: pbyte;
  dst: array[0..2] of pbyte;
  y, i: integer;
  edge_offset: integer;
begin
  width  := frame.w;
  height := frame.h;
  stride := frame.stride;
  edge_offset := FRAME_EDGE_W + FRAME_EDGE_W * stride;
  src := frame.plane_dec[0] - edge_offset;
  for i := 0 to 2 do
      dst[i] := frame.luma_mc[i+1] - edge_offset;

  for y := -FRAME_EDGE_W to height - 1 + FRAME_EDGE_W do begin
      //horiz
      filter_horiz_line_sse2(src, dst[0], width + FRAME_EDGE_W * 2);
      //vert: +8 pre dalsie temp hodnoty pre hvtemp filter
      filter_vert_line_sse2(src, dst[1], width + FRAME_EDGE_W * 2 + 8, stride, tmp);
      //h+v
      tmp[-1] := tmp[0];
      tmp[-2] := tmp[0];
      filter_hvtemp_line_sse2(tmp, dst[2], width + FRAME_EDGE_W * 2);
      //next
      src += stride;
      for i := 0 to 2 do
          dst[i] += stride;
  end;
end;
{$endif}

begin
  {$ifdef FILTER_ASM}
  if filter_use_asm then
      filter_asm(frame.filter_hv_temp + 2)
  else
  {$endif}
      filter_normal();
end;

procedure frame_lowres_from_plane(var frame: frame_t; src, dst: pbyte);
var
  src_stride: integer;
  dst_width,
  dst_height,
  dst_stride: integer;
  y: integer;
begin
  src_stride := frame.stride;

  dst_width  := frame.lowres^.w;
  dst_height := frame.lowres^.h;
  dst_stride := frame.lowres^.stride;

  for y := 0 to dst_height - 1 do begin
      dsp.pixel_downsample_row(src, src_stride, dst, dst_width);
      dst += dst_stride;
      src += src_stride * 2;
  end;
end;

procedure frame_lowres_from_input(var frame: frame_t);
begin
  frame_lowres_from_plane(frame, frame.plane[0], frame.lowres^.plane[0]);
end;

procedure frame_lowres_from_decoded(var frame: frame_t);
begin
  frame_lowres_from_plane(frame, frame.plane_dec[0], frame.lowres^.plane_dec[0]);
end;



(*******************************************************************************
frame_init
*)
procedure frame_init(const flags: TDsp_init_flags);
begin
  filter_use_asm := false;
  {$ifdef FILTER_ASM}
  filter_use_asm := flags.sse2;
  {$endif}
end;


end.

