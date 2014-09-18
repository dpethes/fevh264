; ******************************************************************************
; intra_pred_x86.asm
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
vec_w_8x1:
  times 8 dw 1
vec_w_1_to_8:
  dw 1, 2, 3, 4, 5, 6, 7, 8
vec_w_minus7_to_0:
  dw -7, -6, -5, -4, -3, -2, -1, 0


SECTION .text

cglobal predict_top16_sse2
cglobal predict_left16_mmx
cglobal predict_plane16_sse2


; predict_top16(src, dst: uint8_p)
ALIGN 16
predict_top16_sse2:
    mov eax, [esp+4]    ; src
    mov edx, [esp+8]    ; dest
    movdqu xmm0, [eax+1]
    %assign i 0
    %rep 16
        movdqa [edx + i], xmm0
    %assign i i + 16
    %endrep
    ret


; predict_left16(src, dst: uint8_p)
ALIGN 16
predict_left16_mmx:
    mov eax, [esp+4]    ; src
    mov edx, [esp+8]    ; dest
    add eax, 18
    push ebx
    mov  ebx, 8
.loop:
    movzx   ecx, byte [eax]
    movd    mm0, ecx
    pshufw  mm0, mm0, 0
    packuswb  mm0, mm0
    movzx   ecx, byte [eax+1]
    movd    mm1, ecx
    add     eax, 2
    pshufw  mm1, mm1, 0
    packuswb  mm1, mm1
    movq    [edx   ], mm0
    movq    [edx+ 8], mm0
    movq    [edx+16], mm1
    movq    [edx+24], mm1
    add     edx, 16*2
    dec ebx
    jnz .loop
    pop ebx
    ret


; predict_plane16(src, dst: uint8_p)
ALIGN 16
predict_plane16_sse2:
    mov eax, [esp+4]    ; src
    mov edx, [esp+8]    ; dest
    pxor xmm7, xmm7
    push ebx
    sub esp, 12

;b
    movq xmm0, [eax]          ;0..7
    movq xmm1, [eax + 9]      ;9..16
    punpcklbw xmm0, xmm7
    punpcklbw xmm1, xmm7

    pshufd xmm0, xmm0, 27     ;0..7 -> 7..0
    pshuflw xmm0, xmm0, 177
    pshufhw xmm0, xmm0, 177

    psubw  xmm1, xmm0           ;diff * (i + 1)
    movdqu xmm0, [vec_w_1_to_8]
    pmullw xmm0, xmm1

    movdqa   xmm1, [vec_w_8x1]  ;haddw
    pmaddwd  xmm0, xmm1
    HADDD  xmm0, xmm6

    movd ecx, xmm0              ;(5 * h + 32) >> 6
    imul ecx, 5
    add  ecx, 32
    sar  ecx, 6
    mov [esp+8], ecx
   
;c
    movq xmm2, [eax + 17]
    punpcklbw xmm2, xmm7

    pshufd xmm2, xmm2, 27
    pshuflw xmm2, xmm2, 177
    pshufhw xmm2, xmm2, 177

    movq xmm3, [eax + 17 + 9]
    punpcklbw xmm3, xmm7

    psubw  xmm3, xmm2
    movdqu xmm2, [vec_w_1_to_8]
    pmullw xmm2, xmm3

    movdqa   xmm3, [vec_w_8x1]
    pmaddwd  xmm2, xmm3
    HADDD  xmm2, xmm6

    movd ecx, xmm2
    imul ecx, 5
    add  ecx, 32
    sar  ecx, 6
    mov [esp+4], ecx

;a
    movzx ecx, byte [eax    + 16]
    movzx eax, byte [eax+17 + 16]
    add ecx, eax
    shl ecx, 4
    add ecx, 16
    mov [esp], ecx

;b * (x - 7);
    movd    xmm0, [esp+8]
    pshufd  xmm0, xmm0, 0
    packssdw  xmm0, xmm0 ; b
    movdqa  xmm1, xmm0
    pmullw  xmm0, [vec_w_minus7_to_0] ;b * (x - 7)  [x=-7..0]
    pmullw  xmm1, [vec_w_1_to_8]      ;b * (x - 7)  [x=1..8]
 
 
    mov  ecx, 16
    mov  ebx, -7        ;(y-7)*c, y = 0
    imul ebx, [esp+4]  
.loop:
    mov  eax, ebx
    add  ebx, [esp+4]   ; + c
    add  eax, [esp]  ; (y-7)*c + a = d

    movd    xmm2, eax
    pshufd  xmm2, xmm2, 0
    packssdw  xmm2, xmm2  ; d
    movdqa  xmm3, xmm2

    paddw   xmm2, xmm0    ; b * (x - 7) + d = e
    paddw   xmm3, xmm1    ; b * (x - 7) + d = e
                          
    psraw   xmm2, 5       
    psraw   xmm3, 5       ; e >> 5
    packuswb  xmm2, xmm3      
    movdqu  [edx], xmm2
    add     edx, 16

    dec ecx
    jnz .loop
    
    add esp, 12
    pop ebx

    ret


