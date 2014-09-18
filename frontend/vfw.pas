(*
 vfw parts needed for avisynth script reading
 original vfw.pas header:
*)
(****************************************************************************
 *
 *      VfW.H - Video for windows include file for WIN32
 *
 *      Copyright (c) 1991-1999, Microsoft Corp.  All rights reserved.
 *
 ****************************************************************************)

(******************************************************************************)
(*                                                                            *)
(*  VFW.PAS Conversion by Ronald Dittrich                                     *)
(*                                                                            *)
(*  E-Mail: info@swiftsoft.de                                                 *)
(*  http://www.swiftsoft.de                                                   *)
(*                                                                            *)
(******************************************************************************)

(******************************************************************************)
(*                                                                            *)
(*  Modified: 25.April.2000                                                   *)
(*                                                                            *)
(*  E-Mail:                                                                   *)
(*  Ivo Steinmann: isteinmann@bluewin.ch                                      *)
(*                                                                            *)
(*  Please send all messages regarding specific errors and lacks of this unit *)
(*  to Ivo Steinmann                                                          *)
(*                                                                            *)
(******************************************************************************)

(******************************************************************************)
(*                                                                            *)
(*  Modified: 2000-12-07                                                      *)
(*                                                                            *)
(*  E-Mail:                                                                   *)
(*  Peter Haas: PeterJHaas@t-online.de                                        *)
(*                                                                            *)
(*  Only modified line 1380  ( TAVIPALCHANGE.peNew )                          *)
(*                                                                            *)
(******************************************************************************)

(******************************************************************************)
(*                                                                            *)
(*  Modified: 2007-07-10  (yy/mm/dd)                                          *)
(*                                                                            *)
(*  E-Mail:                                                                   *)
(*  Austin Eshikafe Aigbe: eshikafe@yahoo.co.uk                               *)
(*                                                                            *)
(*  modification: made unit compatible with fpc(free pascal compiler) v1.06   *)
(*                under the Dev-Pas IDE (v 1.9.2). To achieve this            *)
(*                compatibility, a number of modifications were made in the   *)
(*                source code. These have been indicated with the following   *)
(*                headings: Mod. I, mod. II and mod.III respectively          *)
(*   compiled with: Dev-Pascal 1.9.2 (fpc v1.06)                              *)
(******************************************************************************)

unit vfw;

interface

uses
  Windows;

const
  AVIFILDLL = 'avifil32.dll';
  streamtypeVIDEO = $73646976; // FOURCC('v', 'i', 'd', 's')

type
  int = integer;
  HINSTANCE = LongInt;
  FOURCC = DWORD;
  
type
  PAVIStreamInfo = ^TAVIStreamInfo;
  TAVIStreamInfo = packed record
      fccType                 : DWORD;
      fccHandler              : DWORD;
      dwFlags                 : DWORD;        // Contains AVITF_* flags
      dwCaps                  : DWORD;
      wPriority               : WORD;
      wLanguage               : WORD;
      dwScale                 : DWORD;
      dwRate                  : DWORD;        // dwRate / dwScale == samples/second
      dwStart                 : DWORD;
      dwLength                : DWORD;        // In units above...
      dwInitialFrames         : DWORD;
      dwSuggestedBufferSize   : DWORD;
      dwQuality               : DWORD;
      dwSampleSize            : DWORD;
      rcFrame                 : TRECT;
      dwEditCount             : DWORD;
      dwFormatChangeCount     : DWORD;
      szName                  : array[0..63] of AnsiChar;
  end;

  IAVIStream = ^tIAVIStream;
  tIAVIStream = packed record
      QueryInterface : function (idd : IAVIStream; const IID : TGUID; var obj) : HRESULT; stdcall;
  		AddRef : function (idd : IAVIStream) : Longint; stdcall;
  		Release : function (idd : IAVIStream) : Longint; stdcall;

      Create : function(idd : IAVIStream;lParam1, lParam2: LPARAM): HResult; stdcall;
      Info : function(idd : IAVIStream;var psi: TAVIStreamInfo; lSize: LONG): HResult; stdcall;
      FindSample : function(idd : IAVIStream;lPos: LONG; lFlags: LONG): LONG; stdcall;
      ReadFormat : function(idd : IAVIStream;lPos: LONG; lpFormat: PVOID; var lpcbFormat: LONG): HResult; stdcall;
      SetFormat : function(idd : IAVIStream;lPos: LONG; lpFormat: PVOID; cbFormat: LONG): HResult; stdcall;
      Read : function(idd : IAVIStream;lStart: LONG; lSamples: LONG; lpBuffer: PVOID; cbBuffer: LONG; var plBytes, plSamples: LONG): HResult; stdcall;
      Write : function(idd : IAVIStream;lStart: LONG; lSamples: LONG; lpBuffer: PVOID; cbBuffer: LONG; dwFlags: DWORD; var plSampWritten, plBytesWritten: LONG): HResult; stdcall;
      Delete : function(idd : IAVIStream;lStart: LONG; lSamples: LONG): HResult; stdcall;
      ReadData : function(idd : IAVIStream;fcc: DWORD; lp: PVOID; var lpcb: LONG): HResult; stdcall;
      WriteData : function(idd : IAVIStream;fcc: DWORD; lp: PVOID; cb: LONG): HResult; stdcall;
      SetInfo : function(idd : IAVIStream;var lpInfo: TAVIStreamInfo; cbInfo: LONG): HResult; stdcall;
  end;



procedure AVIFileInit; stdcall; external AVIFILDLL;
procedure AVIFileExit; stdcall; external AVIFILDLL;

function  AVIStreamOpenFromFile(var ppavi: IAVISTREAM; szFile: LPCSTR; fccType: DWORD;
  lParam: LONG; mode: UINT; pclsidHandler: PCLSID): HResult; stdcall; external AVIFILDLL name 'AVIStreamOpenFromFileA';

function  AVIStreamInfo(pavi: IAVISTREAM; out psi: TAVISTREAMINFO; lSize: LONG): HResult; stdcall;
external AVIFILDLL name 'AVIStreamInfoA';

function  AVIStreamRead(
    pavi            : IAVISTREAM;
    lStart          : LONG;
    lSamples        : LONG;
    lpBuffer        : PVOID;
    cbBuffer        : LONG;
    plBytes         : PLONG;
    plSamples       : PLONG
    ): HResult; stdcall; external AVIFILDLL;

function  AVIStreamWrite(
    pavi            : IAVISTREAM;
    lStart          : LONG;
    lSamples        : LONG;
    lpBuffer        : PVOID;
    cbBuffer        : LONG;
    dwFlags         : DWORD;
    plSampWritten   : PLONG;
    plBytesWritten  : PLONG
    ): HResult; stdcall; external AVIFILDLL;
    
function  AVIStreamRelease(pavi: IAVISTREAM): ULONG; stdcall; external AVIFILDLL;

function  MKFOURCC(ch0, ch1, ch2, ch3: Char): FOURCC;



implementation

function MKFOURCC( ch0, ch1, ch2, ch3: Char ): FOURCC;
begin
  Result := (DWord(Ord(ch0))) or
            (DWord(Ord(ch1)) shl 8) or
            (DWord(Ord(ch2)) shl 16) or
            (DWord(Ord(ch3)) shl 24);
end;


end.
