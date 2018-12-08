%include "x64inc.asm"

SECTION .text

cglobal core_4x4_mmx
cglobal icore_4x4_mmx

;transpose 4x4 matrix
; in/out: m0..3
; scratch: m5..7
%macro mTRANSPOSE4 0
    movq      mm6, mm0
    movq      mm5, mm1
    punpckldq mm0, mm2
    punpckldq mm1, mm3
    punpckhdq mm6, mm2
    punpckhdq mm5, mm3
    movq      mm7, mm0
    punpcklwd mm0, mm1
    movq      mm2, mm6
    punpckhwd mm7, mm1
    punpcklwd mm2, mm5
    movq      mm1, mm0
    punpckhwd mm6, mm5
    punpckldq mm0, mm7
    movq      mm3, mm2
    punpckhdq mm1, mm7
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
    mTRANSPOSE4
    MULTIPLY_MATRIX_CORE4
    mTRANSPOSE4
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
    mTRANSPOSE4
    MULTIPLY_MATRIX_ICORE4
    mTRANSPOSE4
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


; ******************************************************************************
; transquant_x64.asm
; Copyright (c) 2013-2018 David Pethes
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
