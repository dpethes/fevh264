program check_asm;

{$mode objfpc}{$H+}
{$macro on}

uses
  util, common, pixel, motion_comp, frame, intra_pred, transquant;

const
  unaligned_stride = 17;  //min = 16
  unaligned_offset = 3;
  TIMER_ITERS = 1 shl 24; //clock the cpu
  MBCMP_ITERS = 1 shl 16;
  FRAME_INTERPOLATION_ITERS = 1 shl 8;

var
  flags: TDsp_init_flags;
  src1, src2: pbyte;
  src_mbalign: pbyte;
  unalign_size: integer;
  mb: macroblock_t;
  test_name: string;

  //bench
  tend,
  tstart: Int64;
  tsum: Int64 = 0;
  tcount: integer = 0;
  tskip_count: integer = 0;
  timer_overhead: integer;

{$asmmode intel}
function rdtsc: Int64; assembler; register; nostackframe;
asm
  rdtsc
end;

procedure start_timer; inline;
begin
  tstart := rdtsc;
end;

procedure timer_refresh_stats;
begin
  if ( (tcount < 2) or ((tend - tstart) < max( 8 * tsum div tcount, 2000) ) ) and (tend > tstart) then begin
      tsum += tend - tstart;
      tcount += 1;
  end else begin
      tskip_count += 1;
  end;
end;

procedure stop_timer(); inline;
begin
  tend := rdtsc;
  timer_refresh_stats;
end;

procedure reset_timer();
begin
  tsum := 0;
  tcount := 0;
  tskip_count := 0;
end;

procedure bench_results(tcount_mult: integer = 1);
var
  id: string;
  ttimer: int64;
begin
  id := test_name;
  if flags.avx2 then
      id += '_avx2'
  else if flags.sse2 then
      id += '_sse2'
  else if flags.mmx then
      id += '_mmx'
  else
      id += '_pas';
  if tcount_mult > 1 then begin
      ttimer := tcount * timer_overhead;
      tcount *= tcount_mult;
      writeln((tsum * 10 + ttimer) div tcount:4, ' dezicycles in ', id, ', ', tcount, ' runs, ', tskip_count, ' skips');
  end else begin
      writeln(tsum * 10 div tcount - timer_overhead:4, ' dezicycles in ', id, ', ', tcount, ' runs, ', tskip_count, ' skips');
  end;
end;


procedure init_units(mmx: boolean = false; sse2: boolean = false; ssse3: boolean = false; avx2: boolean = false);
begin
  flags.mmx:=mmx;
  flags.sse2:=sse2;
  flags.ssse3:=ssse3;
  flags.avx2:=avx2;
  //todo switch to dsp init?
  pixel_init(flags);
  motion_compensate_init(flags);
  frame_init(flags);
  intra_pred_init(flags);
  transquant_init(flags);
end;

procedure init_noasm;
begin
  init_units();
end;

procedure init_mmx;
begin
  init_units(true);
end;

procedure init_sse2;
begin
  init_units(true, true);
end;

procedure init_ssse3;
begin
  init_units(true, true, true);
end;

procedure init_avx2;
begin
  init_units(true, true, true, true);
end;

procedure init_src;
var
  i: integer;
begin
  for i := 0 to unalign_size - unaligned_offset - 1 do begin
      src1[i] := Random(256);
      src2[i] := Random(256);
  end;
  for i := 0 to 16*16 - 1 do
      src_mbalign[i] := Random(256);
  for i := 0 to 33 do
      mb.intra_pixel_cache[i] := Random(256);
end;

procedure test(fnname: string);
begin
  test_name := fnname;
  write(fnname:16, ': ');
  reset_timer;
end;


//todo this is not really precise, might as well use a fixed value for a given CPU arch
//replace with multiple fn calls (like x264 does)
procedure test_timer_overhead;
var
  i: integer;
begin
  //warmup
  for i := 0 to TIMER_ITERS - 1 do begin
      start_timer;
      stop_timer;
  end;
  reset_timer;

  for i := 0 to MBCMP_ITERS - 1 do begin
      start_timer;
      stop_timer;
  end;
  timer_overhead := tsum * 10 div tcount;
  writeln('timer: ', timer_overhead);
  reset_timer;

  //sad_4x4_mmx is about 23-26 ticks on Piledriver, so tune for that result
  timer_overhead := 200;
end;

function check_result(const a, b: integer): boolean;
begin
  result := a = b;
  if not result then begin
      writeln('mismatch: ', a, ' - ', b);
  end;
end;

function check_arrays(a, b: pbyte; const length: integer): boolean;
var
  i: integer;
begin
  result := true;
  for i := 0 to length - 1 do begin
      if a^ <> b^ then begin
          result := false;
          writeln('mismatch!');
          exit;
      end;
      a += 1;
      b += 1;
  end;
end;

function check_arrays_with_tolerance(a, b: pbyte; const length, tolerance: integer): boolean;
var
  i: integer;
begin
  result := true;
  for i := 0 to length - 1 do begin
      if abs(a^ - b^) > tolerance then begin
          result := false;
          writeln('mismatch at ', i, ' diff: ', abs(a^ - b^));
          exit;
      end;
      a += 1;
      b += 1;
  end;
end;

procedure test_pixelcmp;
var
  res_noasm, res_asm: integer;
  i: integer;
begin
  test('sad_16x16');
  init_noasm;
  res_noasm := sad_16x16(src_mbalign, src1, unaligned_stride);
  init_sse2;
  res_asm := sad_16x16(src_mbalign, src1, unaligned_stride);

  if check_result(res_noasm, res_asm) then begin
      //benchmark
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          {$define FUNC:=sad_16x16(src_mbalign, src1, unaligned_stride)}
          FUNC;FUNC;FUNC;FUNC;
          stop_timer;
      end;
      bench_results(4);
  end;

  test('sad_8x8');
  init_noasm;
  res_noasm := sad_8x8(src_mbalign, src1, unaligned_stride);
  init_sse2;
  res_asm := sad_8x8(src_mbalign, src1, unaligned_stride);

  if check_result(res_noasm, res_asm) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          {$define FUNC:=sad_8x8(src_mbalign, src1, unaligned_stride)}
          FUNC;FUNC;FUNC;FUNC;
          stop_timer;
      end;
      bench_results(4);
  end;

  test('sad_4x4');
  init_noasm;
  res_noasm := sad_4x4(src_mbalign, src1, unaligned_stride);
  init_sse2;
  res_asm := sad_4x4(src_mbalign, src1, unaligned_stride);

  if check_result(res_noasm, res_asm) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          {$define FUNC:=sad_4x4(src_mbalign, src1, unaligned_stride)}
          FUNC;FUNC;FUNC;FUNC;
          stop_timer;
      end;
      bench_results(4);
  end;

  test('ssd_16x16');
  init_noasm;
  res_noasm := ssd_16x16(src_mbalign, src1, unaligned_stride);
  init_sse2;
  res_asm := ssd_16x16(src_mbalign, src1, unaligned_stride);

  if check_result(res_noasm, res_asm) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          ssd_16x16(src_mbalign, src1, unaligned_stride);
          stop_timer;
      end;
      bench_results();
  end;

  test('ssd_8x8');
  init_noasm;
  res_noasm := ssd_8x8(src_mbalign, src1, unaligned_stride);
  init_sse2;
  res_asm := ssd_8x8(src_mbalign, src1, unaligned_stride);

  if check_result(res_noasm, res_asm) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          ssd_8x8(src_mbalign, src1, unaligned_stride);
          stop_timer;
      end;
      bench_results();
  end;

  test('satd_16x16');
  init_noasm;
  res_noasm := satd_16x16(src_mbalign, src1, unaligned_stride);
  init_sse2;
  res_asm := satd_16x16(src_mbalign, src1, unaligned_stride);

  if check_result(res_noasm, res_asm) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          satd_16x16(src_mbalign, src1, unaligned_stride);
          stop_timer;
      end;
      bench_results();
  end;

  test('satd_16x8');
  init_noasm;
  res_noasm := satd_16x8(src_mbalign, src1, unaligned_stride);
  init_sse2;
  res_asm := satd_16x8(src_mbalign, src1, unaligned_stride);

  if check_result(res_noasm, res_asm) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          satd_16x8(src_mbalign, src1, unaligned_stride);
          stop_timer;
      end;
      bench_results();
  end;

  test('satd_8x8');
  init_noasm;
  res_noasm := satd_8x8(src_mbalign, src1, unaligned_stride);
  init_sse2;
  res_asm := satd_8x8(src_mbalign, src1, unaligned_stride);

  if check_result(res_noasm, res_asm) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          satd_8x8(src_mbalign, src1, unaligned_stride);
          stop_timer;
      end;
      bench_results();
  end;

  test('satd_8x4');
  init_noasm;
  res_noasm := satd_8x4(src_mbalign, src1, unaligned_stride);
  init_sse2;
  res_asm := satd_8x4(src_mbalign, src1, unaligned_stride);

  if check_result(res_noasm, res_asm) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          satd_8x4(src_mbalign, src1, unaligned_stride);
          stop_timer;
      end;
      bench_results();
  end;

  test('satd_4x4');
  init_noasm;
  res_noasm := satd_4x4(src_mbalign, src1, unaligned_stride);
  init_sse2;
  res_asm := satd_4x4(src_mbalign, src1, unaligned_stride);

  if check_result(res_noasm, res_asm) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          satd_4x4(src_mbalign, src1, unaligned_stride);
          stop_timer;
      end;
      bench_results();
  end;

  test('var_16x16');
  init_noasm;
  res_noasm := var_16x16(src_mbalign);
  init_sse2;
  res_asm := var_16x16(src_mbalign);

  if check_result(res_noasm, res_asm) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          var_16x16(src_mbalign);
          stop_timer;
      end;
      bench_results();
  end;
end;


procedure test_transport;
var
  buf_byte: array [0..255] of byte;
  i: integer;
begin
  test('pixel_avg_16x16');
  init_noasm;
  pixel_avg_16x16(src1, src2, src_mbalign, unaligned_stride);
  Move(src_mbalign^, buf_byte, 256);
  init_sse2;
  pixel_avg_16x16(src1, src2, src_mbalign, unaligned_stride);

  if check_arrays(src_mbalign, @buf_byte, 256) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          pixel_avg_16x16(src1, src2, src_mbalign, unaligned_stride);
          stop_timer;
      end;
      bench_results();
  end;

  test('pixel_loadu_16x16');
  init_noasm;
  pixel_loadu_16x16(src_mbalign, src1, unaligned_stride);
  Move(src_mbalign^, buf_byte, 256);
  init_sse2;
  pixel_loadu_16x16(src_mbalign, src1, unaligned_stride);

  if check_arrays(src_mbalign, @buf_byte, 256) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          pixel_loadu_16x16(src_mbalign, src1, unaligned_stride);
          stop_timer;
      end;
      bench_results();
  end;
end;


procedure test_predict;
var
  buf_byte: array [0..255] of byte;
  i: integer;
  res_noasm, res_asm: integer;
begin
  test('predict_plane16');
  init_noasm;
  predict_plane16(@mb.intra_pixel_cache, src_mbalign);
  Move(src_mbalign^, buf_byte, 256);
  FillByte(src_mbalign^, 256, 1);
  init_sse2;
  predict_plane16(@mb.intra_pixel_cache, src_mbalign);

  if check_arrays(src_mbalign, @buf_byte, 256) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          predict_plane16(@mb.intra_pixel_cache, src_mbalign);
          stop_timer;
      end;
      bench_results();
  end;

  test('predict_left16');
  init_noasm;
  predict_left16(@mb.intra_pixel_cache, src_mbalign);
  Move(src_mbalign^, buf_byte, 256);
  FillByte(src_mbalign^, 256, 1);
  init_ssse3;
  predict_left16(@mb.intra_pixel_cache, src_mbalign);

  if check_arrays(src_mbalign, @buf_byte, 256) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          predict_left16(@mb.intra_pixel_cache, src_mbalign);
          stop_timer;
      end;
      bench_results();
  end;
end;


{$codealign localmin=16}
procedure test_transform;
var
  residual: array [0..15] of int16 = (
      5, 11, 8, 10,
      9,  8, 4, 12,
      1, 10, 11, 4,
      19, 6, 15, 7
  );
  decoded_residual: array [0..15] of int16;
  coefficients: array [0..15] of int16;
  quantized_coefficients: array [0..15] of int16;
  xform_buffer: array [0..16 * 4] of int16;
  i: integer;
  qpctx: TQuantCtx;

procedure PrintXform;
var
  i: integer;
begin
  writeln;
  for i := 0 to 15 do begin
      write(xform_buffer[i]:3, ',');
      if (i+1) mod 4 = 0 then writeln;
  end;
  writeln;
end;

begin
  test('core_4x4');
  begin
      init_noasm;
      move(residual, xform_buffer, 2*16);
      core_4x4(@xform_buffer);
      move(xform_buffer, coefficients, 2*16);

      init_mmx;
      move(residual, xform_buffer, 2*16);
      core_4x4(@xform_buffer);

      if check_arrays(@xform_buffer, @coefficients, 2*16) then begin
          for i := 0 to MBCMP_ITERS - 1 do begin
              move(residual, xform_buffer, 2*16);
              move(residual, xform_buffer[16], 2*16);
              move(residual, xform_buffer[32], 2*16);
              move(residual, xform_buffer[48], 2*16);
              start_timer;
              core_4x4(@xform_buffer);
              core_4x4(@xform_buffer[16]);
              core_4x4(@xform_buffer[32]);
              core_4x4(@xform_buffer[48]);
              stop_timer;
          end;
          bench_results(4);
      end;
  end;

  test('icore_4x4');
  begin
      init_noasm;
      move(coefficients, xform_buffer, 2*16);
      icore_4x4(@xform_buffer);
      move(xform_buffer, decoded_residual, 2*16);

      init_mmx;
      move(coefficients, xform_buffer, 2*16);
      icore_4x4(@xform_buffer);

      if check_arrays(@xform_buffer, @decoded_residual, 2*16) then begin
          for i := 0 to MBCMP_ITERS - 1 do begin
              move(coefficients, xform_buffer, 2*16);
              move(coefficients, xform_buffer[16], 2*16);
              move(coefficients, xform_buffer[32], 2*16);
              move(coefficients, xform_buffer[48], 2*16);
              start_timer;
              icore_4x4(@xform_buffer);
              icore_4x4(@xform_buffer[16]);
              icore_4x4(@xform_buffer[32]);
              icore_4x4(@xform_buffer[48]);
              stop_timer;
          end;
          bench_results(4);
      end;
  end;

  test('quant_4x4');
  transqt_init_for_qp(qpctx, 12);
  Fillbyte(xform_buffer, 64*2, 0);
  begin
      init_noasm;
      move(coefficients, xform_buffer, 2*16);
      quant_4x4(@xform_buffer, qpctx.mult_factor, qpctx.f_inter, qpctx.qbits, 1);
      move(xform_buffer, decoded_residual, 2*16);

      init_sse2;
      move(coefficients, xform_buffer, 2*16);
      quant_4x4(@xform_buffer, qpctx.mult_factor, qpctx.f_inter, qpctx.qbits, 1);

      if check_arrays(@xform_buffer, @decoded_residual, 2*16) then begin
          for i := 0 to MBCMP_ITERS - 1 do begin
              move(coefficients, xform_buffer, 2*16);
              start_timer;
              quant_4x4(@xform_buffer, qpctx.mult_factor, qpctx.f_inter, qpctx.qbits, 0);
              stop_timer;
          end;
          bench_results;
      end;
  end;

  test('iquant_4x4');
  begin
      move(coefficients, xform_buffer, 2*16);
      quant_4x4(@xform_buffer, qpctx.mult_factor, qpctx.f_inter, qpctx.qbits, 0);
      move(xform_buffer, quantized_coefficients, 2*16);

      init_noasm;
      iquant_4x4(@xform_buffer, qpctx.rescale_factor, qpctx.qp_div6, 1);
      move(xform_buffer, decoded_residual, 2*16);

      init_sse2;
      move(quantized_coefficients, xform_buffer, 2*16);
      iquant_4x4(@xform_buffer, qpctx.rescale_factor, qpctx.qp_div6, 1);

      init_avx2;
      move(quantized_coefficients, xform_buffer, 2*16);
      iquant_4x4(@xform_buffer, qpctx.rescale_factor, qpctx.qp_div6, 1);

      if check_arrays(@xform_buffer, @decoded_residual, 2*16) then begin
          for i := 0 to MBCMP_ITERS - 1 do begin
              move(coefficients, xform_buffer, 2*16);
              start_timer;
              iquant_4x4(@xform_buffer, qpctx.rescale_factor, qpctx.qp_div6, 1);
              stop_timer;
          end;
          bench_results;
      end;
  end;
end;


procedure test_frame_interpolation;
var
  frame: frame_t;
  i: Integer;
begin
  test('frame hpel');
  dsp.FpuReset;
  frame_new(frame, 16, 8);
  init_noasm;
  frame_hpel_interpolate(frame);
  init_sse2;

  for i := 0 to FRAME_INTERPOLATION_ITERS - 1 do begin
      start_timer;
      frame_hpel_interpolate(frame);
      stop_timer;
  end;
  bench_results();
  frame_free(frame);
end;


procedure test_downsample;
const
  DST_SAMPLES = 32;
var
  //src: array [0..31] of byte = (
  //  1, 1, 2, 2, 3, 3, 1, 1, 1, 1, 1, 1, 8, 8, 1, 1,
  //  1, 1, 2, 2, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2);
  dst_plain, dst_opt: array [0..255] of byte;
  i: Integer;
begin
  test('frame downsample');
  init_noasm;
  FillByte(dst_plain, DST_SAMPLES, 0);
  pixel_downsample_row(src1, 2 * DST_SAMPLES, @dst_plain, DST_SAMPLES);

  init_sse2;
  FillByte(dst_opt, DST_SAMPLES, 0);
  pixel_downsample_row(src1, 2 * DST_SAMPLES, @dst_opt, DST_SAMPLES);

  if check_arrays_with_tolerance(@dst_plain, @dst_opt, DST_SAMPLES, 1) then begin
      for i := 0 to MBCMP_ITERS - 1 do begin
          start_timer;
          pixel_downsample_row(src1, 2 * DST_SAMPLES, @dst_opt, DST_SAMPLES);
          stop_timer;
      end;
      bench_results();
  end;
end;


begin
  //init
  src_mbalign := fev_malloc(16*16);
  unalign_size := 32 * unaligned_stride + unaligned_offset;
  src1 := Getmem(unalign_size);
  src1 += unaligned_offset;
  src2 := Getmem(unalign_size);
  src2 += unaligned_offset;
  init_src;
  test_timer_overhead;
{
  asm
    pcmpeqb xmm6, xmm6
    pcmpeqb xmm7, xmm7
    pcmpeqb xmm8, xmm8
    pcmpeqb xmm9, xmm9
  end;
}

  //tests
  test_pixelcmp;
  test_transport;
  test_predict;
  test_transform;
  test_frame_interpolation;
  //test_downsample;

  //cleanup
  src1 -= unaligned_offset;
  src2 -= unaligned_offset;
  freemem(src1);
  freemem(src2);
  fev_free(src_mbalign);
end.

