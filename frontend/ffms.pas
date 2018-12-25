{
  Copyright (c) 2007-2015 Fredrik Mellbin

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
  THE SOFTWARE.


  Pascal bindings for version 2.23.1.
}
unit ffms;

{$ifdef FPC}
  {$MACRO ON}
  {$IFDEF Windows}
    {$DEFINE extdecl := stdcall; external 'ffms2'}
  {$ELSE}
    //fix{$DEFINE extdecl := cdecl; external 'ffms2'}
  {$ENDIF}
  {$H+}
{$endif}
//else TODO

interface

type
  FFMS_VideoSource = record end;
  FFMS_AudioSource = record end;
  FFMS_Index = record end;
  FFMS_Indexer = record end;
  FFMS_Track = record end;

  PFFMS_VideoSource  = ^FFMS_VideoSource;
  PFFMS_AudioSource  = ^FFMS_AudioSource;
  PFFMS_Index  = ^FFMS_Index;
  PFFMS_Indexer  = ^FFMS_Indexer;
  PFFMS_Track  = ^FFMS_Track;

  PFFMS_ErrorInfo = ^FFMS_ErrorInfo;
  FFMS_ErrorInfo = record
      ErrorType : longint;
      SubType : longint;
      BufferSize : longint;
      Buffer : Pchar;
    end;

  PFFMS_Errors = ^FFMS_Errors;
  FFMS_Errors = (
    FFMS_ERROR_SUCCESS = 0,
    FFMS_ERROR_INDEX = 1,
    FFMS_ERROR_INDEXING,
    FFMS_ERROR_POSTPROCESSING,
    FFMS_ERROR_SCALING,
    FFMS_ERROR_DECODING,
    FFMS_ERROR_SEEKING,
    FFMS_ERROR_PARSER,
    FFMS_ERROR_TRACK,
    FFMS_ERROR_WAVE_WRITER,
    FFMS_ERROR_CANCELLED,
    FFMS_ERROR_RESAMPLING,
    FFMS_ERROR_UNKNOWN = 20,
    FFMS_ERROR_UNSUPPORTED,
    FFMS_ERROR_FILE_READ,
    FFMS_ERROR_FILE_WRITE,
    FFMS_ERROR_NO_FILE,
    FFMS_ERROR_VERSION,
    FFMS_ERROR_ALLOCATION_FAILED,
    FFMS_ERROR_INVALID_ARGUMENT,
    FFMS_ERROR_CODEC,
    FFMS_ERROR_NOT_AVAILABLE,
    FFMS_ERROR_FILE_MISMATCH,
    FFMS_ERROR_USER
    );

  PFFMS_Sources = ^FFMS_Sources;
  FFMS_Sources = (
    FFMS_SOURCE_DEFAULT = $00,
    FFMS_SOURCE_LAVF = $01,
    FFMS_SOURCE_MATROSKA = $02,
    FFMS_SOURCE_HAALIMPEG = $04,
    FFMS_SOURCE_HAALIOGG = $08
    );

  PFFMS_CPUFeatures = ^FFMS_CPUFeatures;
  FFMS_CPUFeatures = (
    FFMS_CPU_CAPS_MMX = $01,
    FFMS_CPU_CAPS_MMX2 = $02,
    FFMS_CPU_CAPS_3DNOW = $04,
    FFMS_CPU_CAPS_ALTIVEC = $08,
    FFMS_CPU_CAPS_BFIN = $10,
    FFMS_CPU_CAPS_SSE2 = $20
    );

  PFFMS_SeekMode = ^FFMS_SeekMode;
  FFMS_SeekMode = (
    FFMS_SEEK_LINEAR_NO_RW = -(1),
    FFMS_SEEK_LINEAR = 0,
    FFMS_SEEK_NORMAL = 1,
    FFMS_SEEK_UNSAFE = 2,
    FFMS_SEEK_AGGRESSIVE = 3
    );

  PFFMS_IndexErrorHandling = ^FFMS_IndexErrorHandling;
  FFMS_IndexErrorHandling = (
    FFMS_IEH_ABORT = 0,
    FFMS_IEH_CLEAR_TRACK = 1,
    FFMS_IEH_STOP_TRACK = 2,
    FFMS_IEH_IGNORE = 3
    );

  PFFMS_TrackType = ^FFMS_TrackType;
  FFMS_TrackType = (
    FFMS_TYPE_UNKNOWN = -(1),
    FFMS_TYPE_VIDEO,
    FFMS_TYPE_AUDIO,
    FFMS_TYPE_DATA,
    FFMS_TYPE_SUBTITLE,
    FFMS_TYPE_ATTACHMENT
    );

  PFFMS_SampleFormat = ^FFMS_SampleFormat;
  FFMS_SampleFormat = (
    FFMS_FMT_U8 = 0,
    FFMS_FMT_S16,
    FFMS_FMT_S32,
    FFMS_FMT_FLT,
    FFMS_FMT_DBL
    );

  PFFMS_AudioChannel = ^FFMS_AudioChannel;
  FFMS_AudioChannel = (
    FFMS_CH_FRONT_LEFT = $00000001,
    FFMS_CH_FRONT_RIGHT = $00000002,
    FFMS_CH_FRONT_CENTER = $00000004,
    FFMS_CH_LOW_FREQUENCY = $00000008,
    FFMS_CH_BACK_LEFT = $00000010,
    FFMS_CH_BACK_RIGHT = $00000020,
    FFMS_CH_FRONT_LEFT_OF_CENTER = $00000040,
    FFMS_CH_FRONT_RIGHT_OF_CENTER = $00000080,
    FFMS_CH_BACK_CENTER = $00000100,
    FFMS_CH_SIDE_LEFT = $00000200,
    FFMS_CH_SIDE_RIGHT = $00000400,
    FFMS_CH_TOP_CENTER = $00000800,
    FFMS_CH_TOP_FRONT_LEFT = $00001000,
    FFMS_CH_TOP_FRONT_CENTER = $00002000,
    FFMS_CH_TOP_FRONT_RIGHT = $00004000,
    FFMS_CH_TOP_BACK_LEFT = $00008000,
    FFMS_CH_TOP_BACK_CENTER = $00010000,
    FFMS_CH_TOP_BACK_RIGHT = $00020000,
    FFMS_CH_STEREO_LEFT = $20000000,
    FFMS_CH_STEREO_RIGHT = $40000000
    );

  PFFMS_Resizers = ^FFMS_Resizers;
  FFMS_Resizers = (
    FFMS_RESIZER_FAST_BILINEAR = $0001,
    FFMS_RESIZER_BILINEAR = $0002,
    FFMS_RESIZER_BICUBIC = $0004,
    FFMS_RESIZER_X = $0008,
    FFMS_RESIZER_POINT = $0010,
    FFMS_RESIZER_AREA = $0020,
    FFMS_RESIZER_BICUBLIN = $0040,
    FFMS_RESIZER_GAUSS = $0080,
    FFMS_RESIZER_SINC = $0100,
    FFMS_RESIZER_LANCZOS = $0200,
    FFMS_RESIZER_SPLINE = $0400
    );

  PFFMS_AudioDelayModes = ^FFMS_AudioDelayModes;
  FFMS_AudioDelayModes = (
    FFMS_DELAY_NO_SHIFT = -(3),
    FFMS_DELAY_TIME_ZERO = -(2),
    FFMS_DELAY_FIRST_VIDEO_TRACK = -(1)
    );

  PFFMS_ColorPrimaries = ^FFMS_ColorPrimaries;
  FFMS_ColorPrimaries = (
    FFMS_PRI_RESERVED0 = 0,
    FFMS_PRI_BT709 = 1,
    FFMS_PRI_UNSPECIFIED = 2,
    FFMS_PRI_RESERVED = 3,
    FFMS_PRI_BT470M = 4,
    FFMS_PRI_BT470BG = 5,
    FFMS_PRI_SMPTE170M = 6,
    FFMS_PRI_SMPTE240M = 7,
    FFMS_PRI_FILM = 8,
    FFMS_PRI_BT2020 = 9
    );

  PFFMS_TransferCharacteristic = ^FFMS_TransferCharacteristic;
  FFMS_TransferCharacteristic = (
    FFMS_TRC_RESERVED0 = 0,
    FFMS_TRC_BT709 = 1,
    FFMS_TRC_UNSPECIFIED = 2,
    FFMS_TRC_RESERVED = 3,
    FFMS_TRC_GAMMA22 = 4,
    FFMS_TRC_GAMMA28 = 5,
    FFMS_TRC_SMPTE170M = 6,
    FFMS_TRC_SMPTE240M = 7,
    FFMS_TRC_LINEAR = 8,
    FFMS_TRC_LOG = 9,
    FFMS_TRC_LOG_SQRT = 10,
    FFMS_TRC_IEC61966_2_4 = 11,
    FFMS_TRC_BT1361_ECG = 12,
    FFMS_TRC_IEC61966_2_1 = 13,
    FFMS_TRC_BT2020_10 = 14,
    FFMS_TRC_BT2020_12 = 15
    );

  PFFMS_ColorSpaces = ^FFMS_ColorSpaces;
  FFMS_ColorSpaces = (
    FFMS_CS_RGB = 0,
    FFMS_CS_BT709 = 1,
    FFMS_CS_UNSPECIFIED = 2,
    FFMS_CS_FCC = 4,
    FFMS_CS_BT470BG = 5,
    FFMS_CS_SMPTE170M = 6,
    FFMS_CS_SMPTE240M = 7,
    FFMS_CS_YCOCG = 8,
    FFMS_CS_BT2020_NCL = 9,
    FFMS_CS_BT2020_CL = 10
    );

  PFFMS_ColorRanges = ^FFMS_ColorRanges;
  FFMS_ColorRanges = (
    FFMS_CR_UNSPECIFIED = 0,
    FFMS_CR_MPEG = 1,
    FFMS_CR_JPEG = 2
    );

  PFFMS_MixingCoefficientType = ^FFMS_MixingCoefficientType;
  FFMS_MixingCoefficientType = (
    FFMS_MIXING_COEFFICIENT_Q8 = 0,
    FFMS_MIXING_COEFFICIENT_Q15 = 1,
    FFMS_MIXING_COEFFICIENT_FLT = 2
    );

  PFFMS_MatrixEncoding = ^FFMS_MatrixEncoding;
  FFMS_MatrixEncoding = (
    FFMS_MATRIX_ENCODING_NONE = 0,
    FFMS_MATRIX_ENCODING_DOBLY = 1,
    FFMS_MATRIX_ENCODING_PRO_LOGIC_II = 2
    );

  PFFMS_ResampleFilterType = ^FFMS_ResampleFilterType;
  FFMS_ResampleFilterType = (
    FFMS_RESAMPLE_FILTER_CUBIC = 0,
    FFMS_RESAMPLE_FILTER_SINC = 1,
    FFMS_RESAMPLE_FILTER_KAISER = 2
    );

  PFFMS_AudioDitherMethod = ^FFMS_AudioDitherMethod;
  FFMS_AudioDitherMethod = (
    FFMS_RESAMPLE_DITHER_NONE = 0,
    FFMS_RESAMPLE_DITHER_RECTANGULAR = 1,
    FFMS_RESAMPLE_DITHER_TRIANGULAR = 2,
    FFMS_RESAMPLE_DITHER_TRIANGULAR_HIGHPASS = 3,
    FFMS_RESAMPLE_DITHER_TRIANGULAR_NOISESHAPING = 4
    );

  PFFMS_LogLevels = ^FFMS_LogLevels;
  FFMS_LogLevels = (
    FFMS_LOG_QUIET = -(8),
    FFMS_LOG_PANIC = 0,
    FFMS_LOG_FATAL = 8,
    FFMS_LOG_ERROR = 16,
    FFMS_LOG_WARNING = 24,
    FFMS_LOG_INFO = 32,
    FFMS_LOG_VERBOSE = 40,
    FFMS_LOG_DEBUG = 48,
    FFMS_LOG_TRACE = 56
    );

  PFFMS_ResampleOptions = ^FFMS_ResampleOptions;
  FFMS_ResampleOptions = record
      ChannelLayout : int64;
      SampleFormat : FFMS_SampleFormat;
      SampleRate : longint;
      MixingCoefficientType : FFMS_MixingCoefficientType;
      CenterMixLevel : double;
      SurroundMixLevel : double;
      LFEMixLevel : double;
      Normalize : longint;
      ForceResample : longint;
      ResampleFilterSize : longint;
      ResamplePhaseShift : longint;
      LinearInterpolation : longint;
      CutoffFrequencyRatio : double;
      MatrixedStereoEncoding : FFMS_MatrixEncoding;
      FilterType : FFMS_ResampleFilterType;
      KaiserBeta : longint;
      DitherMethod : FFMS_AudioDitherMethod;
    end;

  PFFMS_Frame = ^FFMS_Frame;
  FFMS_Frame = record
      Data : array[0..3] of PUint8;
      Linesize : array[0..3] of longint;
      EncodedWidth : longint;
      EncodedHeight : longint;
      EncodedPixelFormat : longint;
      ScaledWidth : longint;
      ScaledHeight : longint;
      ConvertedPixelFormat : longint;
      KeyFrame : longint;
      RepeatPict : longint;
      InterlacedFrame : longint;
      TopFieldFirst : longint;
      PictType : char;
      ColorSpace : longint;
      ColorRange : longint;
      ColorPrimaries : longint;
      TransferCharateristics : longint;
      ChromaLocation : longint;
    end;

  PFFMS_TrackTimeBase = ^FFMS_TrackTimeBase;
  FFMS_TrackTimeBase = record
      Num : int64;
      Den : int64;
    end;

  PFFMS_FrameInfo = ^FFMS_FrameInfo;
  FFMS_FrameInfo = record
      PTS : int64;
      RepeatPict : longint;
      KeyFrame : longint;
    end;

  PFFMS_VideoProperties = ^FFMS_VideoProperties;
  FFMS_VideoProperties = record
      FPSDenominator : longint;
      FPSNumerator : longint;
      RFFDenominator : longint;
      RFFNumerator : longint;
      NumFrames : longint;
      SARNum : longint;
      SARDen : longint;
      CropTop : longint;
      CropBottom : longint;
      CropLeft : longint;
      CropRight : longint;
      TopFieldFirst : longint;
      ColorSpace : longint;
      ColorRange : longint;
      FirstTime : double;
      LastTime : double;
    end;

  PFFMS_AudioProperties = ^FFMS_AudioProperties;
  FFMS_AudioProperties = record
      SampleFormat : longint;
      SampleRate : longint;
      BitsPerSample : longint;
      Channels : longint;
      ChannelLayout : int64;
      NumSamples : int64;
      FirstTime : double;
      LastTime : double;
    end;

  TAudioNameCallback = function(SourceFile: PChar; Track: integer; AP: PFFMS_AudioProperties; FileName: PChar; FNSize: integer; Private_: pointer): integer; {$IFDEF Windows} stdcall; {$endif}
  TIndexCallback = function(Current: int64; Total: int64; ICPrivate: pointer): integer; {$IFDEF Windows} stdcall; {$endif}


procedure FFMS_Init(_para1:longint = 0; _para2:longint = 0);extdecl;
function  FFMS_GetVersion:longint;extdecl;
function  FFMS_GetLogLevel:longint;extdecl;
procedure FFMS_SetLogLevel(Level:longint);extdecl;
function  FFMS_CreateVideoSource(SourceFile:Pchar; Track:longint; Index:PFFMS_Index; Threads:longint; SeekMode:longint; ErrorInfo:PFFMS_ErrorInfo):PFFMS_VideoSource;extdecl;
function  FFMS_CreateAudioSource(SourceFile:Pchar; Track:longint; Index:PFFMS_Index; DelayMode:longint; ErrorInfo:PFFMS_ErrorInfo):PFFMS_AudioSource;extdecl;
procedure FFMS_DestroyVideoSource(V:PFFMS_VideoSource);extdecl;
procedure FFMS_DestroyAudioSource(A:PFFMS_AudioSource);extdecl;
function  FFMS_GetVideoProperties(V:PFFMS_VideoSource):PFFMS_VideoProperties;extdecl;
function  FFMS_GetAudioProperties(A:PFFMS_AudioSource):PFFMS_AudioProperties;extdecl;
function  FFMS_GetFrame(V:PFFMS_VideoSource; n:longint; ErrorInfo:PFFMS_ErrorInfo):PFFMS_Frame;extdecl;
function  FFMS_GetFrameByTime(V:PFFMS_VideoSource; Time:double; ErrorInfo:PFFMS_ErrorInfo):PFFMS_Frame;extdecl;
function  FFMS_GetAudio(A:PFFMS_AudioSource; Buf:pointer; Start:int64; Count:int64; ErrorInfo:PFFMS_ErrorInfo):longint;extdecl;
function  FFMS_SetOutputFormatV2(V:PFFMS_VideoSource; TargetFormats:Plongint; Width:longint; Height:longint; Resizer:longint;ErrorInfo:PFFMS_ErrorInfo):longint;extdecl;
procedure FFMS_ResetOutputFormatV(V:PFFMS_VideoSource);extdecl;
function  FFMS_SetInputFormatV(V:PFFMS_VideoSource; ColorSpace:longint; ColorRange:longint; Format:longint; ErrorInfo:PFFMS_ErrorInfo):longint;extdecl;
procedure FFMS_ResetInputFormatV(V:PFFMS_VideoSource);extdecl;
function  FFMS_CreateResampleOptions(A:PFFMS_AudioSource):PFFMS_ResampleOptions;extdecl;
function  FFMS_SetOutputFormatA(A:PFFMS_AudioSource; options:PFFMS_ResampleOptions; ErrorInfo:PFFMS_ErrorInfo):longint;extdecl;
procedure FFMS_DestroyResampleOptions(options:PFFMS_ResampleOptions);extdecl;
procedure FFMS_DestroyIndex(Index:PFFMS_Index);extdecl;
function  FFMS_GetSourceType(Index:PFFMS_Index):longint;extdecl;
function  FFMS_GetSourceTypeI(Indexer:PFFMS_Indexer):longint;extdecl;
function  FFMS_GetFirstTrackOfType(Index:PFFMS_Index; TrackType:longint; ErrorInfo:PFFMS_ErrorInfo):longint;extdecl;
function  FFMS_GetFirstIndexedTrackOfType(Index:PFFMS_Index; TrackType:longint; ErrorInfo:PFFMS_ErrorInfo):longint;extdecl;
function  FFMS_GetNumTracks(Index:PFFMS_Index):longint;extdecl;
function  FFMS_GetNumTracksI(Indexer:PFFMS_Indexer):longint;extdecl;
function  FFMS_GetTrackType(T:PFFMS_Track):longint;extdecl;
function  FFMS_GetTrackTypeI(Indexer:PFFMS_Indexer; Track:longint):longint;extdecl;
function  FFMS_GetErrorHandling(Index:PFFMS_Index):FFMS_IndexErrorHandling;extdecl;
function  FFMS_GetCodecNameI(Indexer:PFFMS_Indexer; Track:longint):Pchar;extdecl;
function  FFMS_GetFormatNameI(Indexer:PFFMS_Indexer):Pchar;extdecl;
function  FFMS_GetNumFrames(T:PFFMS_Track):longint;extdecl;
function  FFMS_GetFrameInfo(T:PFFMS_Track; Frame:longint):PFFMS_FrameInfo;extdecl;
function  FFMS_GetTrackFromIndex(Index:PFFMS_Index; Track:longint):PFFMS_Track;extdecl;
function  FFMS_GetTrackFromVideo(V:PFFMS_VideoSource):PFFMS_Track;extdecl;
function  FFMS_GetTrackFromAudio(A:PFFMS_AudioSource):PFFMS_Track;extdecl;
function  FFMS_GetTimeBase(T:PFFMS_Track):PFFMS_TrackTimeBase;extdecl;
function  FFMS_WriteTimecodes(T:PFFMS_Track; TimecodeFile:Pchar; ErrorInfo:PFFMS_ErrorInfo):longint;extdecl;
function  FFMS_DefaultAudioFilename(SourceFile:Pchar; Track:longint; AP:PFFMS_AudioProperties; FileName:Pchar; FNSize:longint; Private_:pointer):longint;extdecl;
function  FFMS_CreateIndexer(SourceFile:Pchar; ErrorInfo:PFFMS_ErrorInfo):PFFMS_Indexer;extdecl;
function  FFMS_CreateIndexerWithDemuxer(SourceFile:Pchar; Demuxer:longint; ErrorInfo:PFFMS_ErrorInfo):PFFMS_Indexer;extdecl;
procedure FFMS_TrackIndexSettings(Indexer:PFFMS_Indexer; Track:longint; Index:longint; Dump:longint);extdecl;
procedure FFMS_TrackTypeIndexSettings(Indexer:PFFMS_Indexer; TrackType:longint; Index:longint; Dump:longint);extdecl;
procedure FFMS_SetAudioNameCallback(Indexer:PFFMS_Indexer; ANC:TAudioNameCallback; ANCPrivate:pointer);extdecl;
procedure FFMS_SetProgressCallback(Indexer:PFFMS_Indexer; IC:TIndexCallback; ICPrivate:pointer);extdecl;
function  FFMS_DoIndexing2(Indexer:PFFMS_Indexer; ErrorHandling:longint; ErrorInfo:PFFMS_ErrorInfo):PFFMS_Index;extdecl;
procedure FFMS_CancelIndexing(Indexer:PFFMS_Indexer);extdecl;
function  FFMS_ReadIndex(IndexFile:Pchar; ErrorInfo:PFFMS_ErrorInfo):PFFMS_Index;extdecl;
function  FFMS_ReadIndexFromBuffer(Buffer:PUint8; Size:size_t; ErrorInfo:PFFMS_ErrorInfo):PFFMS_Index;extdecl;
function  FFMS_IndexBelongsToFile(Index:PFFMS_Index; SourceFile:Pchar; ErrorInfo:PFFMS_ErrorInfo):longint;extdecl;
function  FFMS_WriteIndex(IndexFile:Pchar; Index:PFFMS_Index; ErrorInfo:PFFMS_ErrorInfo):longint;extdecl;
function  FFMS_WriteIndexToBuffer(BufferPtr:PPByte; Size:SizeInt; Index:PFFMS_Index; ErrorInfo:PFFMS_ErrorInfo):longint;extdecl;
procedure FFMS_FreeIndexBuffer(BufferPtr:PPByte);extdecl;
function  FFMS_GetPixFmt(Name:Pchar):longint;extdecl;
function  FFMS_GetPresentSources:longint;extdecl;
function  FFMS_GetEnabledSources:longint;extdecl;


implementation

end.
