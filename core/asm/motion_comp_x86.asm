; ******************************************************************************
; motion_comp_x86.asm
; Copyright (c) 2010-2014 David Pethes
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
vec_w_8x32:
  times 8 dw 32  
  

SECTION .text

; all mc functions assume that dest is aligned with 16 byte stride
cglobal mc_chroma_8x8_sse2
cglobal mc_chroma_8x8_sse2.loop


; procedure mc_chroma_8x8_sse2 (src, dst: pbyte; const stride: integer; coef: pbyte); cdecl;

; param: reg, right shift (bytes)
%macro get_coef 2
    mov   ecx, edx
%if %2 > 0    
    shr   ecx, 8 * %2
%endif
    and   ecx, 0xff
    movd  %1, ecx
%endmacro


%macro spread_coef 2
    pshufd    %1, %1, 0
    pshufd    %2, %2, 0
    packssdw  %1, %1
    packssdw  %2, %2
%endmacro


ALIGN 16
mc_chroma_8x8_sse2:
    mov   eax, [esp + 16]
    mov   edx, [eax]
    pxor  xmm7, xmm7
    
    get_coef  xmm0, 0
    get_coef  xmm1, 1
    get_coef  xmm2, 2   
    get_coef  xmm3, 3   
    spread_coef xmm0, xmm1
    spread_coef xmm2, xmm3
    
    ; mc
    mov   eax, [esp+4]   ; src
    mov   edx, [esp+8]   ; dst
    mov   ecx, [esp+12]  ; stride
    push  ebx
    mov   ebx, 8
.loop
    ; A B
    movq      xmm4, [eax]     ; A
    movq      xmm5, [eax+1]   ; B
    movq      xmm6, [eax+ecx] ; C   
    
    punpcklbw xmm4, xmm7
    punpcklbw xmm6, xmm7
    punpcklbw xmm5, xmm7
    
    pmullw    xmm4, xmm0
    pmullw    xmm5, xmm1
    pmullw    xmm6, xmm2
    
    paddw     xmm4, xmm5 ; A + B
    
    movq      xmm5, [eax+ecx+1]  ; D
    paddw     xmm4, [vec_w_8x32] ; A + 32
    punpcklbw xmm5, xmm7
    pmullw    xmm5, xmm3
    paddw     xmm4, xmm6 ; A + C
    paddw     xmm4, xmm5 ; A + D

    add   eax, ecx
    
    psraw     xmm4, 6
    packuswb  xmm4, xmm7
    movq      [edx], xmm4
    add   edx, 16
;endloop    
    dec   ebx
    jnz   .loop
    pop   ebx
    ret
    