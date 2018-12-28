(*******************************************************************************
h264stream.pas
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

unit h264stream;

{$mode objfpc}{$H+}

interface

uses
  util, stdint, common, vlc, bitstream, h264tables;

type
  //SPS
  sps_t = record
      width, height: integer;
      mb_width, mb_height: integer;
      pic_order_cnt_type: byte;
      num_ref_frames: byte;
      log2_max_frame_num_minus4: byte;
      log2_max_pic_order_cnt_lsb_minus4: byte;
  end;

  //PPS
  pps_t = record
      deblocking_filter_control_present_flag: byte;
      qp: byte;
      chroma_qp_offset: shortint;
  end;

  //slice
  slice_header_t = record
      type_: byte;
      is_idr: boolean;
      idr_pic_id: word;
      frame_num: integer;
      qp: integer;
      slice_qp_delta: integer;
      num_ref_frames: byte;
  end;

  TInterPredCost = class;

  { TH264Stream }

  TH264Stream = class
    private
      sps: sps_t;
      pps: pps_t;
      write_sei: boolean;
      write_vui: boolean;
      sei_string: string;

      mb_skip_count: integer;
      bs: TBitstreamWriter;
      slice: slice_header_t;
      last_mb_qp: byte;

      interPredCostEval: TInterPredCost;
      cabac: boolean;
      //stats?

      function GetNoPSkip: boolean;
      procedure SetChromaQPOffset(const AValue: byte);
      procedure SetKeyInterval(const AValue: word);
      procedure SetNumRefFrames(const AValue: byte);
      procedure SetQP(const AValue: byte);
      function  GetSEI: string;
      procedure SetSEI(const AValue: string);
      procedure WriteSliceHeader;
      procedure WriteParamSetsToNAL(var nalstream: TBitstreamWriter);

      procedure write_mb_pred_intra(const mb: macroblock_t);
      procedure write_mb_pred_inter(const mb: macroblock_t);
      procedure write_mb_residual(var mb: macroblock_t);
      procedure write_mb_i_pcm   (var mb: macroblock_t);
      procedure write_mb_i_4x4   (var mb: macroblock_t);
      procedure write_mb_i_16x16 (var mb: macroblock_t);
      procedure write_mb_p_16x16 (var mb: macroblock_t);
      procedure write_mb_p_skip;
      function mb_intrapred_bits(const mb: macroblock_t): integer;
      function mb_residual_bits (const mb: macroblock_t): integer;
      function mb_i_4x4_bits   (const mb: macroblock_t): integer;
      function mb_i_16x16_bits (const mb: macroblock_t): integer;
      function mb_p_16x16_bits (const mb: macroblock_t): integer;
      function mb_p_skip_bits: integer;
      function mb_interpred_bits (const mb: macroblock_t): integer;

    public
      property NumRefFrames: byte read slice.num_ref_frames write SetNumRefFrames;
      property QP: byte             write SetQP;
      property ChromaQPOffset: byte write SetChromaQPOffset;
      property KeyInterval: word    write SetKeyInterval;
      property SEIString: string    read GetSEI write SetSEI;
      property NoPSkipAllowed: boolean  read GetNoPSkip;

      constructor Create(w, h, mbw, mbh: integer);
      destructor Free;
      procedure DisableLoopFilter;
      procedure InitSlice(slicetype, slice_qp, ref_frame_count: integer; bs_buffer: pbyte);
      procedure AbortSlice;
      procedure GetSliceBitstream(var buffer: pbyte; out size: longword);
      procedure WriteMB (var mb: macroblock_t);
      function GetBitCost (const mb: macroblock_t): integer;
      function InterPredCost: TInterPredCost;
  end;

  { TInterPredCost }

  TInterPredCost = class
    private
      _h264stream: TH264Stream;
      _lambda: integer;
      _mvp: motionvec_t;
      _ref_idx: integer;
      _ref_frame_bits: integer;
    public
      constructor Create(const h264stream: TH264Stream);
      procedure SetQP(qp: integer);
      procedure SetMVPredAndRefIdx(const mvp: motionvec_t; const idx: integer);
      function BitCost(const mv: motionvec_t): integer; inline;
      function Bits(const mvx, mvy: integer): integer;
  end;

  function predict_intra_4x4_mode(const modes: array of byte; const i: byte): byte;

implementation

const
//Table 7-1 – NAL unit type codes
NAL_NOIDR = 1;  //Coded slice of a non-IDR picture
NAL_IDR = 5;    //non-partitioned
NAL_SEI = 6;
NAL_SPS = 7;
NAL_PPS = 8;

//Table A-1 – Level limits
LEVEL_DPB: array[0..14, 0..1] of integer = (
  (10,   148),
  (11,   337),
  (12,   891),
  (13,   891),
  (20,   891),
  (21,  1782),
  (22,  3037),
  (30,  3037),
  (31,  6750),
  (32,  7680),
  (40, 12288),
  (41, 12288),
  (42, 12288),
  (50, 41400),
  (51, 69120)
);


function slice2naltype(i: integer): integer;
begin
  case i of
    SLICE_I: result := NAL_IDR;
  else
    result := NAL_NOIDR;
  end;
end;


function get_level(const w, h, refcount: integer): byte;
var
  dpb, i: integer;
begin
  dpb := w * h * 3 div 2 * (refcount + 1) div 1024;
  if dpb > 69120 then begin  //oops, dpb too big
      result := 0;
  end else begin
      i := 0;
      while LEVEL_DPB[i, 1] < dpb do
          i += 1;
      result := byte( LEVEL_DPB[i, 0] );
  end;
end;


{
3.104 raw byte sequence payload (RBSP): A syntax structure containing an integer number of bytes that is
encapsulated in a NAL unit. An RBSP is either empty or has the form of a string of data bits containing syntax
elements followed by an RBSP stop bit and followed by zero or more subsequent bits equal to 0.

3.105 raw byte sequence payload (RBSP) stop bit: A bit equal to 1 present within a raw byte sequence payload
(RBSP) after a string of data bits. The location of the end of the string of data bits within an RBSP can be
identified by searching from the end of the RBSP for the RBSP stop bit, which is the last non-zero bit in the
RBSP.


NAL + annex B

3.130 start code prefix: A unique sequence of three bytes equal to 0x000001 embedded in the byte stream as a prefix
to each NAL unit. The location of a start code prefix can be used by a decoder to identify the beginning of a
new NAL unit and the end of a previous NAL unit. Emulation of start code prefixes is prevented within NAL
units by the inclusion of emulation prevention bytes.

7.4.1
emulation_prevention_three_byte is a byte equal to 0x03. When an emulation_prevention_three_byte is present in the
NAL unit, it shall be discarded by the decoding process.
The last byte of the NAL unit shall not be equal to 0x00.
Within the NAL unit, the following three-byte sequences shall not occur at any byte-aligned position:
– 0x000000
– 0x000001
– 0x000002
Within the NAL unit, any four-byte sequence that starts with 0x000003 other than the following sequences shall not
occur at any byte-aligned position:
– 0x00000300
– 0x00000301
– 0x00000302
– 0x00000303
}
//NAL encapsulate RBSP (raw byte seq.payload)
procedure NAL_encapsulate(var rbsp: TBitstreamWriter; var nalstream: TBitstreamWriter; const naltype: integer);
var
  nal_ref_idc: integer = 3;
  i, len: integer;
  a: pbyte;
begin
  //rbsp_trailing_bits
  rbsp.Write(1);
  rbsp.ByteAlign;
  rbsp.Close;
  a   := rbsp.DataStart;
  len := rbsp.ByteSize;
  nal_ref_idc := 3;
  if naltype = NAL_SEI then nal_ref_idc := 0;

  //annex B:  0x00000001
  nalstream.Write(1, 32);
  //nal: forbidden_zero_bit | nal_ref_idc | nal_unit_type
  nalstream.Write((nal_ref_idc shl 5) or naltype, 8);
  //emulation prevention
  i := 0;
  while i < len do begin
      //cycle to catch repeated occurences
      while (i + 2 < len) and (a[0] = 0) and (a[1] = 0) and (a[2] in [0,1,2,3]) do begin
          nalstream.Write(3, 24); //0x000003
          a += 2;
          i += 2;
      end;
      nalstream.Write(a^, 8);
      a += 1;
      i += 1;
  end;
end;



{
write SPS/PPS to NAL unit

bits(SODB) -> RBSP

3.131 string of data bits (SODB): A sequence of some number of bits representing syntax elements present within a
raw byte sequence payload prior to the raw byte sequence payload stop bit. Within an SODB, the left-most bit
is considered to be the first and most significant bit, and the right-most bit is considered to be the last and least
significant bit.


7.3.2.1 Sequence parameter set RBSP syntax

profile: baseline
}

procedure TH264Stream.WriteParamSetsToNAL(var nalstream: TBitstreamWriter);
const
  sei_uuid = '2011012520091007';
var
  b: TBitstreamWriter;
  rbsp: array[0..255] of byte;
  i: integer;
  sei_text: string;
  level: byte;
begin
  level := get_level(sps.mb_width * 16, sps.mb_height * 16, sps.num_ref_frames);

  //SPS
  b := TBitstreamWriter.Create(@rbsp);

  b.Write(66, 8);             //profile_idc u(8) (annex A)
  b.Write(1);                 //constraint_set0_flag u(1)
  b.Write(0);                 //constraint_set1_flag u(1)
  b.Write(0);                 //constraint_set2_flag u(1)
  b.Write(0, 5);              //reserved_zero_5bits /* equal to 0 */ 0 u(5)
  b.Write(level, 8);          //level_idc 0 u(8)

  write_ue_code(b, 0);        //seq_parameter_set_id 0 ue(v)
  write_ue_code(b, sps.log2_max_frame_num_minus4);
                              //log2_max_frame_num_minus4 0 ue(v)
  write_ue_code(b, sps.pic_order_cnt_type);
                              //pic_order_cnt_type ue(v)
  if sps.pic_order_cnt_type = 0 then
      write_ue_code(b, sps.log2_max_pic_order_cnt_lsb_minus4);
                              //log2_max_pic_order_cnt_lsb_minus4
  write_ue_code(b, sps.num_ref_frames);
                              //num_ref_frames  ue(v)
  b.Write(0);                 //gaps_in_frame_num_value_allowed_flag 0 u(1)
  write_ue_code(b, sps.mb_width  - 1);    //pic_width_in_mbs_minus1 0 ue(v)
  write_ue_code(b, sps.mb_height - 1);    //pic_height_in_map_units_minus1 0 ue(v)
  b.Write(1);                 //frame_mbs_only_flag         u(1)
  b.Write(0);                 //direct_8x8_inference_flag   u(1)

  //cropping
  if ((sps.width or sps.height) and $f) = 0 then
      b.Write(0)              //frame_cropping_flag         u(1)
  else begin
      b.Write(1);             //offsets:
      write_ue_code(b, 0);    //left, right
      write_ue_code(b, (sps.mb_width  * 16 - sps.width ) div 2);
      write_ue_code(b, 0);    //top, bottom
      write_ue_code(b, (sps.mb_height * 16 - sps.height) div 2);
  end;

  //VUI
  if write_vui then begin
      b.Write(1);             //vui_parameters_present_flag u(1)
      b.Write(0);             //aspect_ratio_info_present_flag
      b.Write(0);             //overscan_info_present_flag
      b.Write(0);             //video_signal_type_present_flag
      b.Write(0);             //chroma_loc_info_present_flag
      b.Write(1);             //timing_info_present_flag
      //if( timing_info_present_flag )
          b.Write( 1, 32);    //num_units_in_tick
          b.Write(50, 32);    //time_scale
          b.Write(1);         //fixed_frame_rate_flag
      b.Write(0);             //nal_hrd_parameters_present_flag
      b.Write(0);             //vcl_hrd_parameters_present_flag
      b.Write(0);             //pic_struct_present_flag
      b.Write(0);             //bitstream_restriction_flag
  end else
      b.Write(0);

  NAL_encapsulate(b, nalstream, NAL_SPS);
  b.Free;

  //PPS
  b := TBitstreamWriter.Create(@rbsp);

  write_ue_code(b, 0);        //pic_parameter_set_id   ue(v)
  write_ue_code(b, 0);        //seq_parameter_set_id   ue(v)
  if cabac then b.Write(1) else b.Write(0);
                              //entropy_coding_mode_flag  u(1)
  b.Write(0);                 //pic_order_present_flag    u(1)
  write_ue_code(b, 0);        //num_slice_groups_minus1   ue(v)

  write_ue_code(b, sps.num_ref_frames - 1);  //num_ref_idx_l0_active_minus1 ue(v)
  write_ue_code(b, 0);        //num_ref_idx_l1_active_minus1 ue(v)
  b.Write(0);                 //weighted_pred_flag  u(1)
  b.Write(0, 2);              //weighted_bipred_idc u(2)

  write_se_code(b, pps.qp - 26);
                              //pic_init_qp_minus26 /* relative to 26 */ 1 se(v)
  write_se_code(b, 0);        //pic_init_qs_minus26 /* relative to 26 */ 1 se(v)
  write_se_code(b, pps.chroma_qp_offset);
                              //chroma_qp_index_offset [-12.. 12] se(v)

  b.Write(pps.deblocking_filter_control_present_flag);  //deblocking_filter_control_present_flag 1 u(1)
  b.Write(0);                 //constrained_intra_pred_flag    u(1)
  b.Write(0);                 //redundant_pic_cnt_present_flag u(1)

  //T-REC-H.264-200503
{
  b.Write(0);                 //8x8 transform flag
  b.Write(0);                 //scaling matrix
  write_se_code(b, -3);       //second chroma qp offset
}

  NAL_encapsulate(b, nalstream, NAL_PPS);
  b.Free;

  //sei; payload_type = 5 (user_data_unregistered)
  if write_sei then begin
      sei_text := 'fevh264 ' + sei_string;

      b := TBitstreamWriter.Create(@rbsp);
      b.Write(5, 8);          //last_payload_type_byte

      i := Length(sei_uuid) + Length(sei_text);
      while i > 255 do begin
          b.Write(255, 8);    //ff_byte
          i -= 255;
      end;
      b.Write(i, 8);          //last_payload_size_byte
      for i := 1 to Length(sei_uuid) do
          b.Write(byte( sei_uuid[i] ), 8);
      for i := 1 to Length(sei_text) do
          b.Write(byte( sei_text[i] ), 8);

      NAL_encapsulate(b, nalstream, NAL_SEI);
      b.Free;
  end;

  //write aux. info only once
  write_vui := false;
  write_sei := false;
end;



(*******************************************************************************
7.3.2.8 Slice layer without partitioning RBSP syntax
  slice_layer_without_partitioning_rbsp( ) {
      slice_header( )
      slice_data( ) /* all categories of slice_data( ) syntax */
      rbsp_slice_trailing_bits( )
  }
*******************************************************************************)

{
slice header

slicetype
0,1,2 + 5,6,7 = p,b,i
if slicetype > 4: all slicetypes in current frame will be equal

frame_num
is used as an identifier for pictures and shall be represented by log2_max_frame_num_minus4 + 4 bits in the bitstream.
frame_num = 0 for IDR slices
}
procedure TH264Stream.WriteSliceHeader;
var
  nal_unit_type,
  nal_ref_idc: byte;
begin
  nal_ref_idc := 1;
  if slice.is_idr then
      nal_unit_type := NAL_IDR
  else
      nal_unit_type := NAL_NOIDR;

  write_ue_code(bs, 0);                      //first_mb_in_slice   ue(v)
  write_ue_code(bs, slice.type_);            //slice_type          ue(v)
  write_ue_code(bs, 0);                      //pic_parameter_set_id  ue(v)
  bs.Write(slice.frame_num, 4 + sps.log2_max_frame_num_minus4);
  if nal_unit_type = NAL_IDR {5} then
      write_ue_code(bs, slice.idr_pic_id);   //idr_pic_id 2 ue(v)
  if sps.pic_order_cnt_type = 0 then begin
      bs.Write(slice.frame_num * 2, 4 + sps.log2_max_pic_order_cnt_lsb_minus4);
                                             //pic_order_cnt_lsb u(v)
  end;
  if slice.type_ = SLICE_P then begin
      //reduce ref count to encoded gop frame count
      if slice.frame_num + 1 > sps.num_ref_frames then
          bs.Write(0)                        //num_ref_idx_active_override_flag  u(1)
      else begin
          bs.Write(1);
          write_ue_code(bs, slice.frame_num - 1);  //num_ref_idx_l0_active_minus1
      end;
  end;
  //ref_pic_list_reordering( )
  if slice.type_ <> SLICE_I then begin
      bs.Write(0);                           //ref_pic_list_reordering_flag_l0  u(1)
  end;
  //dec_ref_pic_marking( )
  if nal_ref_idc <> 0 then begin
      if nal_unit_type = NAL_IDR then begin
          bs.Write(0);                       //no_output_of_prior_pics_flag  u(1)
          bs.Write(0);                       //long_term_reference_flag  u(1)
      end else begin
          bs.Write(0);                       //adaptive_ref_pic_marking_mode_flag u(1)
      end;
  end;
  write_se_code(bs, slice.slice_qp_delta);   //slice_qp_delta se(v)
  if pps.deblocking_filter_control_present_flag > 0 then begin
      write_ue_code(bs, 1);                  //disable_deblocking_filter_idc ue(v)
  end;
end;



{ close slice data bitstream, encapsulate in NAL
}
procedure h264s_write_slice_to_nal (const slice: slice_header_t; var slice_bs, nal_bs: TBitstreamWriter);
var
  nal_unit_type: byte;
begin
  if slice.is_idr then begin
      if slice.type_ <> SLICE_I then
          writeln('[h264s_write_slice_to_nal] IDR NAL for slicetype <> SLICE_I!');
      nal_unit_type := NAL_IDR;
  end else
      nal_unit_type := NAL_NOIDR;
  NAL_encapsulate(slice_bs, nal_bs, nal_unit_type);
end;

{ TH264Stream }

procedure TH264Stream.SetChromaQPOffset(const AValue: byte);
begin
  pps.chroma_qp_offset := AValue;
end;

function TH264Stream.GetNoPSkip: boolean;
begin
  result := mb_skip_count + 1 > MB_SKIP_MAX;
end;

procedure TH264Stream.SetKeyInterval(const AValue: word);
begin
  sps.log2_max_frame_num_minus4 := max(num2log2(AValue) - 4, 0);
  sps.log2_max_pic_order_cnt_lsb_minus4 := sps.log2_max_frame_num_minus4 + 1;
end;

procedure TH264Stream.SetNumRefFrames(const AValue: byte);
begin
   sps.num_ref_frames := AValue;
end;

procedure TH264Stream.SetQP(const AValue: byte);
begin
  pps.qp := AValue;
end;

function TH264Stream.GetSEI: string;
begin
  result := sei_string;
end;

procedure TH264Stream.SetSEI(const AValue: string);
begin
  sei_string := AValue;
end;


(*******************************************************************************
mode is derived from surrounding blocks of current or neighboring mbs (if available)

8.3.1.1 Derivation process for the Intra4x4PredMode

predIntra4x4PredMode = Min( intra4x4PredModeA, intra4x4PredModeB )
if( prev_intra4x4_pred_mode_flag[ luma4x4BlkIdx ] )
    Intra4x4PredMode[ luma4x4BlkIdx ] = predIntra4x4PredMode
else
    if( rem_intra4x4_pred_mode[ luma4x4BlkIdx ] < predIntra4x4PredMode )
        Intra4x4PredMode[ luma4x4BlkIdx ] = rem_intra4x4_pred_mode[ luma4x4BlkIdx ]
    else
        Intra4x4PredMode[ luma4x4BlkIdx ] = rem_intra4x4_pred_mode[ luma4x4BlkIdx ] + 1


mode = min( pred_mode_A, pred_mode_B )
if mode = pred_mode_cur
    write pred_mode_flag = 1
else
    write pred_mode_flag = 0
    if pred_mode < mode
        write mode
    else
        write mode - 1

a,b idx pair table:
  A
B Cur
     16   17   18   19
    +-----------------
20  | 0 |  1 |  4 |  5
    |---+----+----+---
21  | 2 |  3 |  6 |  7
    |---+----+----+---
22  | 8 |  9 | 12 | 13
    |---+----+----+---
23  |10 | 11 | 14 | 15

(16, 20), (17,  0), ( 0, 21), ( 1,  2),
(18,  1), (19,  4), ( 4,  3), ( 5,  6),
( 2, 21), ( 3,  8), ( 8, 23), ( 9, 10),
( 6,  9), ( 7, 12), (12, 11), (13, 14)

*)
function predict_intra_4x4_mode(const modes: array of byte; const i: byte): byte;
const
  idx: array[0..15, 0..1] of byte = (
    (16, 20), (17,  0), ( 0, 21), ( 1,  2),
    (18,  1), (19,  4), ( 4,  3), ( 5,  6),
    ( 2, 22), ( 3,  8), ( 8, 23), ( 9, 10),
    ( 6,  9), ( 7, 12), (12, 11), (13, 14)
  );
var
  a, b: byte;
begin
  a := modes[ idx[i, 0] ];
  b := modes[ idx[i, 1] ];
  if a + b >= INTRA_PRED_NA then
      result := INTRA_PRED_DC
  else
      result := min(a, b);
end;


procedure TH264Stream.write_mb_pred_intra(const mb: macroblock_t);
var
  mode,          //current block intrapred mode
  pred: byte;    //predicted intrapred mode
  i: byte;
begin
  //Luma (MB_I_4x4 only; MB_I_16x16 prediction is derived from mbtype)
  if mb.mbtype = MB_I_4x4 then
      for i := 0 to 15 do begin
          pred := predict_intra_4x4_mode(mb.i4_pred_mode, i);
          mode := mb.i4_pred_mode[i];

          if pred = mode then
              bs.Write(1)               //prev_intra4x4_pred_mode_flag[ luma4x4BlkIdx ] 2 u(1) | ae(v)
          else begin
              bs.Write(0);              //prev_intra4x4_pred_mode_flag
              if mode < pred then
                  bs.Write(mode, 3)     //rem_intra4x4_pred_mode[ luma4x4BlkIdx ] 2 u(3) | ae(v)
              else
                  bs.Write(mode - 1, 3)
          end;
      end;

  //Chroma
  write_ue_code(bs, mb.chroma_pred_mode);  //intra_chroma_pred_mode  ue(v)
end;

procedure TH264Stream.write_mb_pred_inter(const mb: macroblock_t);
var
  x, y: int16;
begin
  //ref_idx_l0
  case slice.num_ref_frames of
    1: ;
    2: bs.Write(1 - mb.ref);      //te() = !value; value = <0,1>
  else
      write_ue_code(bs, mb.ref);  //te() = ue()
  end;

  //mvd L0
  x := mb.mv.x - mb.mvp.x;
  y := mb.mv.y - mb.mvp.y;
  write_se_code(bs, x);
  write_se_code(bs, y);
end;


procedure TH264Stream.write_mb_residual(var mb: macroblock_t);
var
  bits, i: integer;
begin
  write_se_code(bs, mb.qp - last_mb_qp);  //mb_qp_delta
  last_mb_qp := mb.qp;
  bits := bs.BitSize;

  //luma
  if mb.mbtype = MB_I_16x16 then begin
      cavlc_encode(mb, mb.block[24], 0, RES_LUMA_DC, bs);
      if (mb.cbp and %1111) > 0 then
          for i := 0 to 15 do
              cavlc_encode(mb, mb.block[i], i, RES_LUMA_AC, bs);
  end else
      for i := 0 to 15 do
          if (mb.cbp and (1 shl (i div 4))) > 0 then
              cavlc_encode(mb, mb.block[i], i, RES_LUMA, bs);

  //chroma
  if mb.cbp shr 4 > 0 then begin
      //dc
      for i := 0 to 1 do
          cavlc_encode(mb, mb.block[25 + i], i, RES_DC, bs);
      //ac
      if mb.cbp shr 5 > 0 then begin
          for i := 0 to 3 do
              cavlc_encode(mb, mb.block[16 + i], i, RES_AC_U, bs);
          for i := 0 to 3 do
              cavlc_encode(mb, mb.block[16 + 4 + i], i, RES_AC_V, bs);
      end;
  end;

  mb.residual_bits := bs.BitSize - bits;
end;

constructor TH264Stream.Create(w, h, mbw, mbh: integer);
const
  QP_DEFAULT = 26;
begin
  sps.width  := w;
  sps.height := h;
  sps.mb_width  := mbw;
  sps.mb_height := mbh;
  sps.pic_order_cnt_type := 0;
  write_vui := true;
  write_sei := true;
  sei_string := '';

  pps.qp := QP_DEFAULT;
  pps.chroma_qp_offset := 0;
  pps.deblocking_filter_control_present_flag := 0;

  slice.frame_num := 0;
  slice.is_idr    := true;
  slice.idr_pic_id := 0;
  slice.type_ := SLICE_I;
  slice.qp    := QP_DEFAULT;
  slice.slice_qp_delta := 0;
  slice.num_ref_frames := 1;

  cabac := false;

  interPredCostEval := TInterPredCost.Create(self);
end;

destructor TH264Stream.Free;
begin
  interPredCostEval.Free;
end;

procedure TH264Stream.DisableLoopFilter;
begin
  pps.deblocking_filter_control_present_flag := 1;
end;


procedure TH264Stream.InitSlice(slicetype, slice_qp, ref_frame_count: integer; bs_buffer: pbyte);
begin
  bs := TBitstreamWriter.Create(bs_buffer);

  slice.type_ := slicetype;
  slice.qp    := slice_qp;
  slice.slice_qp_delta := slice.qp - pps.qp;
  slice.num_ref_frames := ref_frame_count;
  if slice.type_ = SLICE_I then begin
      slice.is_idr    := true;
      slice.frame_num := 0;
  end else begin
      slice.is_idr    := false;
      slice.frame_num += 1;
  end;

  WriteSliceHeader;

  mb_skip_count := 0;
  last_mb_qp := slice.qp;
end;

procedure TH264Stream.AbortSlice;
begin
  bs.Free;
end;


procedure TH264Stream.GetSliceBitstream(var buffer: pbyte; out size: longword);
var
  nalstream: TBitstreamWriter;
begin
  //convert to nal, write sps/pps
  nalstream := TBitstreamWriter.Create(buffer);
  if slice.type_ = SLICE_I then begin
      WriteParamSetsToNAL(nalstream);
      if slice.idr_pic_id = 65535 then
          slice.idr_pic_id := 0
      else
          slice.idr_pic_id += 1;
  end;
  h264s_write_slice_to_nal(slice, bs, nalstream);
  nalstream.Close;
  size := nalstream.ByteSize;

  nalstream.Free;
  bs.Free;
end;


//PCM mb - no compression
procedure TH264Stream.write_mb_i_pcm(var mb: macroblock_t);
var
  i, j, chroma_idx: integer;
begin
  //skip run, mbtype
  if slice.type_ = SLICE_P then begin
      write_ue_code(bs, mb_skip_count);
      mb_skip_count := 0;
      write_ue_code(bs, 25 + 5);
  end else
      write_ue_code(bs, 25);  //I_PCM - tab. 7-8

  bs.ByteAlign;
  for i := 0 to 255 do bs.Write(mb.pixels[i], 8);
  for chroma_idx := 0 to 1 do
      for i := 0 to 7 do
          for j := 0 to 7 do
              bs.Write(mb.pixels_c[chroma_idx][i*16 + j], 8);
end;


procedure TH264Stream.write_mb_i_4x4(var mb: macroblock_t);
begin
  //skip run, mbtype
  if slice.type_ = SLICE_P then begin
      write_ue_code(bs, mb_skip_count);
      mb_skip_count := 0;
      write_ue_code(bs, 0 + 5);  //I_4x4 in P - tab. 7-10
  end else
      write_ue_code(bs, 0);  //I_4x4 - tab. 7-8
  //mb_pred
  write_mb_pred_intra(mb);
  //cbp
  write_ue_code(bs, tab_cbp_intra_4x4_to_codenum[mb.cbp]);
  if mb.cbp > 0 then
      write_mb_residual(mb);
end;

  { derive mb_type:
    I_16x16_(pred_mode16)_(cbp_chroma[0..2])_(cbp_luma[0, 15])
  }
function mb_I_16x16_mbtype_num(const cbp, pred: integer): integer; inline;
begin
  result := 1 + pred + (cbp shr 4) * 4;
  if cbp and %1111 > 0 then
      result += 12;
end;

procedure TH264Stream.write_mb_i_16x16(var mb: macroblock_t);
var
  mbt: integer;
begin
  mbt := mb_I_16x16_mbtype_num(mb.cbp, mb.i16_pred_mode);
  if slice.type_ = SLICE_P then begin
      write_ue_code(bs, mb_skip_count); //skip run
      mb_skip_count := 0;
      write_ue_code(bs, 5 + mbt); //I_16x16 in P - tab. 7-10
  end else
      write_ue_code(bs, mbt);     //I_16x16 - tab. 7-8
  write_mb_pred_intra(mb);     //mb_pred
  write_mb_residual(mb);
end;


procedure TH264Stream.write_mb_p_16x16(var mb: macroblock_t);
begin
  //skip run, mbtype
  write_ue_code(bs, mb_skip_count);
  mb_skip_count := 0;
  write_ue_code(bs, 0);  //P_L0_16x16 - tab. 7-10
  //mb_pred
  write_mb_pred_inter(mb);
  //cbp
  write_ue_code(bs, tab_cbp_inter_4x4_to_codenum[mb.cbp]);
  if mb.cbp > 0 then
      write_mb_residual(mb);
end;

procedure TH264Stream.write_mb_p_skip;
begin
  mb_skip_count += 1;
end;

procedure TH264Stream.WriteMB(var mb: macroblock_t);
begin
  case mb.mbtype of
      MB_I_PCM:
          write_mb_i_pcm(mb);
      MB_I_4x4:
          write_mb_i_4x4(mb);
      MB_I_16x16:
          write_mb_i_16x16(mb);
      MB_P_16x16:
          write_mb_p_16x16(mb);
      MB_P_SKIP:
          write_mb_p_skip;
  end;
end;

function TH264Stream.GetBitCost(const mb: macroblock_t): integer;
begin
  case mb.mbtype of
      MB_I_4x4:
          result := mb_i_4x4_bits(mb);
      MB_I_16x16:
          result := mb_i_16x16_bits(mb);
      MB_P_16x16:
          result := mb_p_16x16_bits(mb);
      MB_P_SKIP:
          result := mb_p_skip_bits;
  else
      result := 256 + 2 * 64;
  end;
end;


//bitcost functions
function TH264Stream.mb_interpred_bits(const mb: macroblock_t): integer;
var
  x, y: int16;
begin
  result := 0;
  case slice.num_ref_frames of
    1: ;
    2: result += 1;
  else
      result += ue_code_len(mb.ref);
  end;
  x := mb.mv.x - mb.mvp.x;
  y := mb.mv.y - mb.mvp.y;
  result += se_code_len(x) + se_code_len(y);
end;

function TH264Stream.InterPredCost: TInterPredCost;
begin
  result := interPredCostEval;
end;


function TH264Stream.mb_intrapred_bits(const mb: macroblock_t): integer;
var
  mode,          //current block intrapred mode
  pred: byte;    //predicted intrapred mode
  i: byte;
begin
  result := 0;
  //Luma
  if mb.mbtype = MB_I_4x4 then begin
      result := 16; //prev_intra4x4_pred_mode_flag
      for i := 0 to 15 do begin
          pred := predict_intra_4x4_mode(mb.i4_pred_mode, i);
          mode := mb.i4_pred_mode[i];

          if pred <> mode then
              result += 3;
      end;
  end;
  //Chroma
  result += ue_code_len(mb.chroma_pred_mode);
end;


function TH264Stream.mb_residual_bits(const mb: macroblock_t): integer;
var
  i: byte;
begin
  result := 0;

  if mb.mbtype = MB_I_16x16 then begin
      result += cavlc_block_bits(mb, mb.block[24], 0, RES_LUMA_DC);
      if (mb.cbp and %1111) > 0 then
          for i := 0 to 15 do
              result += cavlc_block_bits(mb, mb.block[i], i, RES_LUMA_AC);
  end else
      for i := 0 to 15 do
          if (mb.cbp and (1 shl (i div 4))) > 0 then
              result += cavlc_block_bits(mb, mb.block[i], i, RES_LUMA);

  if mb.cbp shr 4 > 0 then begin
      for i := 0 to 1 do
          result += cavlc_block_bits(mb, mb.block[25 + i], i, RES_DC);
      if mb.cbp shr 5 > 0 then begin
          for i := 0 to 3 do
              result += cavlc_block_bits(mb, mb.block[16 + i], i, RES_AC_U);
          for i := 0 to 3 do
              result += cavlc_block_bits(mb, mb.block[16 + 4 + i], i, RES_AC_V);
      end;
  end;
end;


function TH264Stream.mb_i_4x4_bits(const mb: macroblock_t): integer;
begin
  if slice.type_ = SLICE_P then
      result := ue_code_len(5)
  else
      result := ue_code_len(0);
  result += mb_intrapred_bits(mb);
  result += ue_code_len( tab_cbp_intra_4x4_to_codenum[mb.cbp] );
  if mb.cbp > 0 then
      result += mb_residual_bits(mb);
end;

function TH264Stream.mb_i_16x16_bits(const mb: macroblock_t): integer;
var
  mbt: integer;
begin
  mbt := mb_I_16x16_mbtype_num(mb.cbp, mb.i16_pred_mode);
  if slice.type_ = SLICE_P then
      result := ue_code_len(5 + mbt)
  else
      result := ue_code_len(mbt);
  result += mb_intrapred_bits(mb);
  result += mb_residual_bits(mb);
end;

function TH264Stream.mb_p_16x16_bits(const mb: macroblock_t): integer;
begin
  result := 1 + mb_interpred_bits(mb);
  result += ue_code_len(tab_cbp_inter_4x4_to_codenum[mb.cbp]);
  if mb.cbp > 0 then
      result += mb_residual_bits(mb);
end;

function TH264Stream.mb_p_skip_bits: integer;
begin
  result := ue_code_len(mb_skip_count + 1) - ue_code_len(mb_skip_count);
end;

{ TInterPredCost }

const
  lambda_mv: array[0..51] of byte = (
      0,0,0,0,0,0,0,1,1,1,
      1,1,1,1,1,1,1,2,2,2,
      2,3,3,3,4,4,5,5,6,7,
      7,8,9,10,12,13,15,17,19,21,
      23,26,30,33,37,42,47,53,59,66,
      74,83
  );

procedure TInterPredCost.SetMVPredAndRefIdx(const mvp: motionvec_t; const idx: integer);
begin
  _mvp := mvp;
  _ref_idx := idx;
  case _h264stream.NumRefFrames of
      1: _ref_frame_bits := 0;
      2: _ref_frame_bits := 1;
  else
      _ref_frame_bits := ue_code_len(_ref_idx);
  end;
end;

constructor TInterPredCost.Create(const h264stream: TH264Stream);
begin
  _h264stream := h264stream;
  _lambda := 1;
  _mvp := ZERO_MV;
  _ref_idx := 0;
end;

procedure TInterPredCost.SetQP(qp: integer);
begin
  _lambda := lambda_mv[qp];
end;

function TInterPredCost.BitCost(const mv: motionvec_t): integer;
begin
  result := Bits(mv.x, mv.y);
end;

function TInterPredCost.Bits(const mvx, mvy: integer): integer;
begin
  result := _ref_frame_bits + se_code_len(mvx - _mvp.x) + se_code_len(mvy - _mvp.y);
  result *= _lambda;
end;


end.

