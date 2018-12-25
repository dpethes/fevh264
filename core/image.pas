(*******************************************************************************
image.pas
Copyright (c) 2010-2018 David Pethes

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
unit image;
{$mode objfpc}{$H+}

interface

uses
  util;

const
  QPARAM_AUTO = 255;

type
  { TPlanarImage }

  TPlanarImage = class
    private
      w, h: integer;
      qp: byte;
      function GetHeight: integer;
      function GetQParam: byte;
      function GetWidth: integer;
      procedure SetQParam(const AValue: byte);
    public
      frame_num: integer;
      plane: array[0..2] of pbyte; //pointers to image planes (0 - luma; 1,2 - chroma U/V)
      stride, stride_c: integer;   //plane strides (0 - luma; 1,2 - chroma U/V)

      property QParam: byte read GetQParam write SetQParam;
      property Width: integer read GetWidth;
      property Height: integer read GetHeight;

      constructor Create(const width_, height_: integer);
      constructor Create(const width_, height_, stride_p0, stride_p12: integer);
      destructor Destroy; override;
      procedure SwapUV;
  end;


implementation

{ TPlanarImage }

function TPlanarImage.GetQParam: byte;
begin
  result := qp;
end;

function TPlanarImage.GetHeight: integer;
begin
  result := h;
end;

function TPlanarImage.GetWidth: integer;
begin
  result := w;
end;

procedure TPlanarImage.SetQParam(const AValue: byte);
begin
  if AValue > 51 then
      qp := QPARAM_AUTO
  else
      qp := AValue;
end;

constructor TPlanarImage.Create(const width_, height_: integer);
begin
  Create(width_, height_, width_, width_ div 2);
end;

constructor TPlanarImage.Create(const width_, height_, stride_p0, stride_p12: integer);
var
  memsize: integer;
begin
  w := width_;
  h := height_;
  stride   := stride_p0;
  stride_c := stride_p12;

  memsize := stride_p0 * h + 2 * (stride_p12 * (h div 2));
  plane[0] := getmem(memsize);
  plane[1] := plane[0] + stride_p0  * h;
  plane[2] := plane[1] + stride_p12 * (h div 2);
  qp := QPARAM_AUTO;
end;

destructor TPlanarImage.Destroy;
begin
  freemem(plane[0]);
end;

procedure TPlanarImage.SwapUV;
begin
  swap_ptr(plane[1], plane[2]);
end;

end.

