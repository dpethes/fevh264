; ******************************************************************************
; frame_x86.asm
; Copyright (c) 2010 David Pethes
;
; This file is part of Fev.
;
; Fev is free software: you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation, either version 3 of the License, or
; (at your option) any later version.
;
; Fev is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY;  without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
;
; You should have received a copy of the GNU General Public License
; along with Fev.  If not, see <http://www.gnu.org/licenses/>.
;
; ******************************************************************************


BITS 32

%include "x86inc.asm"

SECTION .rodata
ALIGN 16
filter_coefs:
  dw 1, -5, 20, 20, -5, 1, 0, 0
vec_w_8x1:
  times 8 dw  1
vec_w_8x_5:
  times 8 dw -5
vec_w_8x16:
  times 8 dw 16
vec_w_8x20:
  times 8 dw 20
vec_d_4x16:
  times 4 dd 16
vec_d_4x512:
  times 4 dd 512



SECTION .text

cglobal filter_horiz_line_sse2
cglobal filter_vert_line_sse2
cglobal filter_hvtemp_line_sse2

; for profiling
cglobal filter_horiz_line_sse2.loop
cglobal filter_vert_line_sse2.loop
cglobal filter_hvtemp_line_sse2.loop


; filter macros

; param: 6x 16bit pixels in xmm reg
; in: out: xmm3; tmp: xmm1
; xmm6 - filter coefs
; xmm7 - 0
%macro filter_horiz_w 1
    pmaddwd   %1, xmm6
    psrldq    xmm3, 4
    HADDD     %1, xmm1
    pslldq    %1, 12
    por       xmm3, %1
%endmacro


; param: add vector xmm reg, shift bits
; in: xmm3; out: xmm3;
; xmm7 - 0
%macro filter_scale_tmp 2
    paddd     xmm3, [%1]  ; rounding
    psrad     xmm3, %2    ; shift
    packssdw  xmm3, xmm3
    packuswb  xmm3, xmm7  ; clip
%endmacro


; procedure filter_horiz_line (src, dest: uint8_p; width: integer); cdecl;
ALIGN 16
filter_horiz_line_sse2:
    mov   eax, [esp+4]    ; src
    mov   edx, [esp+8]    ; dest
    mov   ecx, [esp+12]   ; width
    push  ebx
    shr   ecx, 2
    sub   eax, 2
    pxor      xmm7, xmm7  ; 0
    movdqa    xmm6, [filter_coefs]

.loop:
    pxor      xmm3, xmm3
    movq      xmm0, [eax]
    punpcklbw xmm0, xmm7
    movq      xmm2, [eax + 1]
    punpcklbw xmm2, xmm7
    movq      xmm4, [eax + 2]
    punpcklbw xmm4, xmm7
    movq      xmm5, [eax + 3]
    punpcklbw xmm5, xmm7
    filter_horiz_w xmm0
    filter_horiz_w xmm2
    filter_horiz_w xmm4
    filter_horiz_w xmm5
    add       eax, 4

    filter_scale_tmp vec_d_4x16, 5
    movd      [edx], xmm3
    add       edx, 4

;endloop
    dec       ecx
    jnz .loop

    pop   ebx
    ret


; procedure filter_hvtemp_line_sse2 (src: int16_p; dest: uint8_p; width: integer); cdecl;
ALIGN 16
filter_hvtemp_line_sse2:
    mov   eax, [esp+4]    ; src
    mov   edx, [esp+8]    ; dest
    mov   ecx, [esp+12]   ; width
    push  ebx
    shr   ecx, 2
    sub   eax, 4
    pxor      xmm7, xmm7  ; 0
    movdqa    xmm6, [filter_coefs]

.loop:
    pxor      xmm3, xmm3
    movdqu    xmm0, [eax]
    filter_horiz_w  xmm0
    movdqu    xmm0, [eax + 2]
    filter_horiz_w  xmm0
    movdqu    xmm0, [eax + 4]
    filter_horiz_w  xmm0
    movdqu    xmm0, [eax + 6]
    filter_horiz_w  xmm0
    add       eax, 8

    filter_scale_tmp vec_d_4x512, 10
    movd      [edx], xmm3
    add       edx, 4

;endloop
    dec       ecx
    jnz .loop

    pop   ebx
    ret



; procedure filter_vert_line_sse2 (src, dest: uint8_p; width: integer; stride: integer; tmp: psmallint); cdecl;

%macro madd_3bw 3  ; 1x20, 2x-5, 3x1
    punpcklbw %1, xmm7
    punpcklbw %2, xmm7
    punpcklbw %3, xmm7
    pmullw    %1, [vec_w_8x20]
    pmullw    %2, [vec_w_8x_5]
    pmullw    %3, [vec_w_8x1]
    paddw     %1, %2
    paddw     %1, %3
%endmacro

ALIGN 16
filter_vert_line_sse2:
    mov   eax, [esp+4]    ; src
    mov   edx, [esp+8]    ; dest
    mov   ecx, [esp+12]   ; width
    push  ebx
    mov   ebx, [esp+20]   ; stride
    push  edi
    mov   edi, [esp+28]
    push  esi

    shr   ecx, 3          ; we are doing 8 values at time
    lea   esi, [eax + ebx]
    sub   eax, ebx
    sub   eax, ebx
    pxor      xmm7, xmm7  ; 0

.loop:
    ;0, -1, -2
    movq      xmm0, [eax + 2 * ebx]
    movq      xmm1, [eax + ebx]
    movq      xmm2, [eax]
    add       eax, 8
    madd_3bw  xmm0, xmm1, xmm2

    ;1, 2, 3
    movq      xmm3, [esi]
    movq      xmm1, [esi + ebx]
    movq      xmm2, [esi + 2 * ebx]
    add       esi, 8
    madd_3bw  xmm3, xmm1, xmm2
    paddw     xmm0, xmm3

    movdqu    [edi], xmm0
    add       edi, 16

    paddw     xmm0, [vec_w_8x16]
    psraw     xmm0, 5
    packuswb  xmm0, xmm7  ; clip
    movq      [edx], xmm0

    add       edx, 8

;endloop
    dec       ecx
    jnz .loop

    pop   esi
    pop   edi
    pop   ebx
    ret



