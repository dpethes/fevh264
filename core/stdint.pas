unit stdint;
{$mode objfpc}
interface

type
int8_t  = shortint;
int16_t = smallint;
int32_t = longint;
int64_t = int64;

uint8_t  = byte;
uint16_t = word;
uint32_t = longword;
uint64_t = qword;

int8_p  = ^shortint;
int16_p = ^smallint;
int32_p = ^longint;
int64_p = ^int64;

uint8_p  = ^byte;
uint16_p = ^word;
uint32_p = ^longword;
uint64_p = ^qword;

int  = integer;
pint = ^integer;


int8  = shortint;
int16 = smallint;
int32 = longint;

uint8  = byte;
uint16 = word;
uint32 = longword;

implementation
end.
