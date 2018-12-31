%include "x64inc.asm"

SECTION .text

cglobal core_4x4_mmx
cglobal icore_4x4_mmx
cglobal quant_4x4_sse2
cglobal iquant_4x4_sse2

; transpose 4x4 matrix of int16-s
; in/out: m0..3
; scratch: m5, m6
%macro TRANSPOSE_4x4_int16 0
    movq      mm5, mm0
    movq      mm6, mm2
    punpcklwd mm0, mm1
    punpcklwd mm2, mm3
    punpckhwd mm5, mm1
    punpckhwd mm6, mm3
    movq      mm1, mm0
    punpckldq mm0, mm2
    punpckhdq mm1, mm2
    movq      mm2, mm5
    movq      mm3, mm5
    punpckldq mm2, mm6
    punpckhdq mm3, mm6
%endmacro

; core transform for 4x4 matrix
; in: m0..m3 (a..d)
; out:  m0..m3
; scratch: m4, m6, m7
%macro MULTIPLY_MATRIX_CORE4 0
    movq   mm7, mm3  ; save d
    paddw  mm3, mm0  ; e = a + d (=> d + a)
    psubw  mm0, mm7  ; f = a - d
    
    movq   mm7, mm2  ; save c
    paddw  mm2, mm1  ; g = b + c (=> c + b)
    psubw  mm1, mm7  ; h = b - c
    
    movq   mm7, mm2  ; save g
    paddw  mm2, mm3  ; a' = a + b +  c +  d (=> g + e)
    psubw  mm3, mm7  ; c' = a - b -  c +  d (=> e - g)
    
    movq   mm7, mm1  ; save h
    movq   mm6, mm0  ; save f
    paddw  mm0, mm0  ; 2f
    paddw  mm1, mm0  ; b' = 2a + b -  c - 2d (=> h + 2f)
    psubw  mm0, mm6  ; restore f
    paddw  mm7, mm7  ; 2h
    psubw  mm0, mm7  ; d' = a -2b + 2c -  d  (=> f - 2h)
    
    ; reorder from (d',b',a',c')
    movq  mm4, mm2
    movq  mm2, mm3
    movq  mm3, mm0
    movq  mm0, mm4
%endmacro

; inverse core transform for 4x4 matrix
; in: m0..m3 (a..d)
; out:  m0..m3
; scratch: m4, m6, m7
%macro MULTIPLY_MATRIX_ICORE4 0
    movq   mm7, mm2  ; save c
    paddw  mm2, mm0  ; e = a + c (=> c + a)
    psubw  mm0, mm7  ; f = a - c
    
    movq   mm7, mm3  ; save d
    psraw  mm3, 1    ; d>>1
    movq   mm6, mm1  ; save b
    psraw  mm1, 1    ; b>>1
    paddw  mm3, mm6  ; g = b + d>>1 (=> d>>1 + b)
    psubw  mm1, mm7  ; h = b>>1 - d
   
    movq   mm7, mm3  ; save g
    paddw  mm3, mm2  ; a' = (=> g + e)
    psubw  mm2, mm7  ; d' = (=> e - g)
    
    movq   mm7, mm1  ; save h
    paddw  mm1, mm0  ; b' = (=> h + f)
    psubw  mm0, mm7  ; c' = (=> f - h)
    
    ; reorder from (c',b',d',a')
    movq  mm4, mm0
    movq  mm0, mm3
    movq  mm3, mm2
    movq  mm2, mm4
%endmacro

; core_4x4_mmx (int16)
ALIGN 16
core_4x4_mmx:
    movq  mm0, [r1]
    movq  mm1, [r1+8]
    movq  mm2, [r1+16]
    movq  mm3, [r1+24]
    MULTIPLY_MATRIX_CORE4
    TRANSPOSE_4x4_int16
    MULTIPLY_MATRIX_CORE4
    TRANSPOSE_4x4_int16
    movq  [r1]   , mm0
    movq  [r1+8] , mm1
    movq  [r1+16], mm2
    movq  [r1+24], mm3
    ret
    
; icore_4x4_mmx (int16)
ALIGN 16
icore_4x4_mmx:
    movq  mm0, [r1]
    movq  mm1, [r1+8]
    movq  mm2, [r1+16]
    movq  mm3, [r1+24]
    TRANSPOSE_4x4_int16
    MULTIPLY_MATRIX_ICORE4
    TRANSPOSE_4x4_int16
    ; generate constant 32(word) for rounding
    pcmpeqb mm5, mm5
    psrlw   mm5, 15
    psllw   mm5, 5
    MULTIPLY_MATRIX_ICORE4
    ; rescale
    paddw   mm0, mm5
    psraw   mm0, 6
    paddw   mm1, mm5
    psraw   mm1, 6
    paddw   mm2, mm5
    psraw   mm2, 6
    paddw   mm3, mm5
    psraw   mm3, 6
    movq  [r1]   , mm0
    movq  [r1+8] , mm1
    movq  [r1+16], mm2
    movq  [r1+24], mm3
    ret

; quant_4x4_sse2(block: pInt16; mf: pInt16; f: integer; qbits: integer; starting_index: integer)
ALIGN 16
quant_4x4_sse2
    PUSH_XMM_REGS 1
    movd    xmm3, r3   ; f
    pshufd  xmm3, xmm3, 0
    movd    xmm4, r4   ; qbits
    pxor    xmm6, xmm6
    mov r4, 4
    mov     ax, [r1] 
.loop
    movq    xmm0, [r1]
    movq    xmm1, [r2]
    movdqa   xmm5, xmm0
    pcmpgtw  xmm5, xmm6   ; greater than 0 mask

    movdqa  xmm2, xmm0
    pmullw  xmm0, xmm1
    pmulhw  xmm2, xmm1
    punpcklwd xmm0, xmm2  ; block * mf

    movdqa  xmm1, xmm3
    psubd   xmm1, xmm0    ; f - block * mf
    psrld   xmm1, xmm4    ; >> qbits
    pxor    xmm2, xmm2
    psubd   xmm2, xmm1    ; negate
    packssdw xmm2, xmm2   ; convert to int16

    paddd   xmm0, xmm3    ; block * mf + f
    psrld   xmm0, xmm4    ; >> qbits
    packssdw xmm0, xmm0   ; convert to int16

    pand    xmm0, xmm5    ; merge lanes
    pandn   xmm5, xmm2
    por     xmm0, xmm5
    movq    [r1], xmm0

    add r1, 8
    add r2, 8
    dec r4
    jnz .loop
    
    bind_param_5  r10     ; restore first coefficient if desired
    cmp r10b, 0
    jz .done
    mov [r1-32], ax
.done:
    POP_XMM_REGS 1
    ret

; iquant_4x4_sse2(block: pInt16; mf: pInt16; shift: integer; starting_idx: integer)
ALIGN 16
iquant_4x4_sse2
    movd    xmm4, r3   ; shift
    mov     ax, [r1] 

    movdqa    xmm0, [r1]
    movdqu    xmm1, [r2]
    pmullw  xmm0, xmm1    ; block * mf
    psllw   xmm0, xmm4    ; << shift
    movdqa    [r1], xmm0

    movdqa    xmm0, [r1+16]
    movdqu    xmm1, [r2+16]
    pmullw  xmm0, xmm1
    psllw   xmm0, xmm4
    movdqa    [r1+16], xmm0
   
    mov r10, r4
    cmp r10b, 0
    jz .done
    mov [r1], ax
.done:
    ret


; ******************************************************************************
; transquant_x64.asm
; Copyright (c) 2018 David Pethes
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
