(*******************************************************************************
bitstream.pas
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

unit bitstream;
{$mode objfpc}

interface

type

  { TBitstreamWriter }

  TBitstreamWriter = class
    private
      buffer: plongword;
      cur: plongword;
      mask: longword;
      closed: boolean;
      function GetBitSize: longword;
      function GetByteSize: longword;
      function GetDataStart: pbyte;

    public
      property BitSize:  longword read GetBitSize;
      property ByteSize: longword read GetByteSize;
      property DataStart: pbyte read GetDataStart;
      constructor Create(const memory_buffer: pbyte);
      destructor Free;
      procedure Close;
      function IsByteAligned: boolean;
      procedure ByteAlign;
      procedure Write(const bit: integer);
      procedure Write(bits, bit_count: longword);
  end;


(*******************************************************************************
*******************************************************************************)
implementation

//fpc has SwapEndian, but it doesn't get inlined
function bswap(n: longword): longword; inline;
begin
  result := (n shr 24) or
            (n shl 24) or
            ((n shr 8) and $ff00) or
            ((n shl 8) and $ff0000);
end;


{ TBitstreamWriter }

function TBitstreamWriter.GetBitSize: longword;
begin
  result := 32 * (cur - buffer) + (32 - integer(mask));
end;

function TBitstreamWriter.GetByteSize: longword;
begin
  result := (cur - buffer) * 4;
  result += (32 - mask + 7) div 8;  //+ buffer
end;

function TBitstreamWriter.GetDataStart: pbyte;
begin
  result := pbyte(buffer);
end;

constructor TBitstreamWriter.Create(const memory_buffer: pbyte);
begin
  buffer := plongword (memory_buffer);
  cur  := buffer;
  cur^ := 0;
  mask := 32;
end;

destructor TBitstreamWriter.Free;
begin
  if not closed then
      Close;
end;

procedure TBitstreamWriter.Close;
begin
  if not closed then begin
      if mask < 32 then
          cur^ := bswap(cur^);
      closed := true;
  end;
end;

function TBitstreamWriter.IsByteAligned: boolean;
begin
  result := mask mod 8 = 0;
end;

procedure TBitstreamWriter.ByteAlign;
begin
  while not IsByteAligned do
      Write(0);
end;

procedure TBitstreamWriter.Write(const bit: integer);
begin
  mask -= 1;
  cur^ := cur^ or longword((bit and 1) shl mask);

  if mask = 0 then begin
      cur^ := bswap(cur^);
      cur += 1;
      cur^ := 0;
      mask := 32;
  end;
end;

procedure TBitstreamWriter.Write(bits, bit_count: longword);
var
  bits_left: longword;
begin
  assert(bit_count <= 32, 'bit_count over 32');
  assert(bits = bits and ($ffffffff shr (32 - bit_count)), 'more than bit_count bits set');
  if mask > bit_count then begin
      mask -= bit_count;
      cur^ := cur^ or (bits shl mask);
  end
  else begin
      bits_left := bit_count - mask;
      mask := 32 - bits_left;
      cur^ := cur^ or (bits shr bits_left);
      cur^ := bswap(cur^);
      cur += 1;
      cur^ := 0;
      if bits_left > 0 then
          cur^ := bits shl mask;
  end;
end;


end.

