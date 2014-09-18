; ******************************************************************************
; pixel_x86.asm
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
vec_w_8x1:
  times 8 dw  1


SECTION .text

cglobal sad_16x16_mmx
cglobal sad_16x16_sse2
cglobal sad_8x8_mmx
cglobal sad_4x4_mmx
cglobal ssd_16x16_sse2
cglobal ssd_8x8_sse2
cglobal var_16x16_sse2
cglobal pixel_load_16x16_sse2
cglobal pixel_loadu_16x16_sse2
cglobal pixel_load_8x8_mmx
cglobal pixel_save_16x16_sse2
cglobal pixel_save_8x8_mmx
cglobal pixel_sub_4x4_mmx
cglobal pixel_add_4x4_mmx
cglobal pixel_avg_16x16_sse2
cglobal satd_4x4_mmx
cglobal satd_8x8_mmx
cglobal satd_16x16_mmx
cglobal satd_16x16_sse2


; for profiling
cglobal ssd_16x16_sse2.loop
cglobal ssd_8x8_sse2.loop
cglobal var_16x16_sse2.loop
cglobal satd_8x8_mmx.loop
cglobal satd_16x16_mmx.loop
cglobal satd_16x16_sse2.loop


; SAD
; function sad_16x16_mmx(pix1, pix2: pbyte; stride: integer): integer; cdecl;
ALIGN 16
sad_16x16_mmx:
    mov   eax, [esp+4]
    mov   edx, [esp+8]
    mov   ecx, [esp+12]
    pxor  mm5, mm5
    pxor  mm6, mm6
%rep 15
    movq    mm0, [edx]
    movq    mm2, [edx+8]
    psadbw  mm0, [eax]
    psadbw  mm2, [eax+8]
    add     eax, 16
    add     edx, ecx
    paddq   mm5, mm0
    paddq   mm6, mm2
%endrep
    movq    mm0, [edx]
    movq    mm2, [edx+8]
    psadbw  mm0, [eax]
    psadbw  mm2, [eax+8]
    paddq   mm5, mm0
    paddq   mm6, mm2
    paddq   mm6, mm5
    movd    eax, mm6
    ret
    

; sad_16x16_sse2
ALIGN 16
sad_16x16_sse2:
    mov   eax, [esp+4]
    mov   edx, [esp+8]
    mov   ecx, [esp+12]
    pxor  xmm5, xmm5
    pxor  xmm6, xmm6
%rep 8
    movdqu  xmm0, [edx]
    psadbw  xmm0, [eax]    
    movdqu  xmm2, [edx + ecx]
    psadbw  xmm2, [eax + MBSTRIDE]
    add     eax, 2 * MBSTRIDE
    lea     edx, [edx + 2 * ecx]
    paddq   xmm5, xmm0
    paddq   xmm6, xmm2
%endrep
    paddq   xmm6, xmm5
    HADDQ   xmm6, xmm0
    movd    eax, xmm6
    ret


; sad_8x8_mmx
ALIGN 16
sad_8x8_mmx:
    mov   eax, [esp+4]
    mov   edx, [esp+8]
    mov   ecx, [esp+12]
    pxor  mm5, mm5
%rep 7
    movq    mm0, [edx]
    movq    mm1, [eax]
    psadbw  mm0, mm1
    add     eax, 16
    add     edx, ecx
    paddq   mm5, mm0
%endrep
    movq    mm0, [edx]
    movq    mm1, [eax]
    psadbw  mm0, mm1
    paddq   mm5, mm0
    movd    eax, mm5
    ret


; sad_4x4_mmx
ALIGN 16
sad_4x4_mmx:
    mov   eax, [esp+4]
    mov   edx, [esp+8]
    mov   ecx, [esp+12]
    pxor  mm5, mm5
%rep 3
    movd    mm0, [edx]
    movd    mm1, [eax]
    psadbw  mm0, mm1
    add     eax, 16
    add     edx, ecx
    paddq   mm5, mm0
%endrep
    movd    mm0, [edx]
    movd    mm1, [eax]
    psadbw  mm0, mm1
    paddq   mm5, mm0
    movd    eax, mm5
    ret


; SSD
; function ssd_16x16_sse2(pix1, pix2: pbyte; stride: integer): integer; cdecl;
ALIGN 16
ssd_16x16_sse2:
    mov   eax, [esp+4]  ; pix1
    mov   edx, [esp+8]  ; pix2
    mov   ecx, [esp+12] ; stride
    push  ebx
    pxor  xmm6, xmm6    ; accum
    pxor  xmm7, xmm7    ; zero
    mov   ebx, 16       ; counter
.loop:
    movdqa    xmm0, [eax]
    movdqa    xmm1, xmm0
    movdqu    xmm2, [edx]
    movdqa    xmm3, xmm2
    punpcklbw xmm0, xmm7
    punpckhbw xmm1, xmm7
    punpcklbw xmm2, xmm7
    punpckhbw xmm3, xmm7
    psubsw    xmm0, xmm2
    psubsw    xmm1, xmm3
    pmaddwd   xmm0, xmm0
    pmaddwd   xmm1, xmm1
    paddd     xmm6, xmm0
    paddd     xmm6, xmm1
    add   eax, 16
    add   edx, ecx
    dec   ebx
    jnz   .loop
    pop   ebx
    HADDD xmm6, xmm0
    movd  eax,  xmm6
    ret


; SSD 8x8
ALIGN 16
ssd_8x8_sse2:
    mov   eax, [esp+4]  ; pix1
    mov   edx, [esp+8]  ; pix2
    mov   ecx, [esp+12] ; stride
    push  ebx
    pxor  xmm6, xmm6    ; accum
    pxor  xmm7, xmm7    ; zero
    mov   ebx, 8        ; counter
.loop:
    movq      xmm0, [eax]
    movq      xmm2, [edx]
    punpcklbw xmm0, xmm7
    punpcklbw xmm2, xmm7
    psubsw    xmm0, xmm2
    pmaddwd   xmm0, xmm0
    add       eax, 16
    add       edx, ecx
    paddd     xmm6, xmm0
    dec       ebx
    jnz .loop
    pop       ebx
    HADDD     xmm6, xmm0
    movd      eax, xmm6
    ret



; variance
; function var_16x16_sse2(pixels: pbyte): integer; cdecl;
ALIGN 16
var_16x16_sse2:
    mov   eax, [esp+4]   ; pixels
    mov   edx, 8
    pxor  xmm5, xmm5     ; sum
    pxor  xmm6, xmm6     ; sum squared
    pxor  xmm7, xmm7     ; zero
.loop:
    movdqa    xmm0, [eax]
    movdqa    xmm1, xmm0
    movdqa    xmm3, [eax+16]
    movdqa    xmm2, xmm0
    punpcklbw xmm0, xmm7
    movdqa    xmm4, xmm3
    punpckhbw xmm1, xmm7
    add       eax, 32
    punpckhbw xmm4, xmm7
    psadbw    xmm2, xmm7
    paddw     xmm5, xmm2
    movdqa    xmm2, xmm3
    punpcklbw xmm3, xmm7
    dec       edx
    psadbw    xmm2, xmm7
    pmaddwd   xmm0, xmm0
    paddw     xmm5, xmm2
    pmaddwd   xmm1, xmm1
    paddd     xmm6, xmm0
    pmaddwd   xmm3, xmm3
    paddd     xmm6, xmm1
    pmaddwd   xmm4, xmm4
    paddd     xmm6, xmm3
    paddd     xmm6, xmm4
    jnz  .loop
    movhlps   xmm0, xmm5
    paddw     xmm5, xmm0
    movd  eax, xmm5      ; sqr - sum * sum >> shift
    mul   eax
    HADDD     xmm6, xmm1
    shr   eax, 8
    mov   edx, eax
    movd  eax, xmm6
    sub   eax, edx
    ret



; procedure pixel_load_16x16_sse2 (dest, src: uint8_p; stride: uint32_t); cdecl;
ALIGN 16
pixel_load_16x16_sse2:
    mov   edx, [esp+4]      ; dest
    mov   eax, [esp+8]      ; src
    mov   ecx, [esp+12]     ; stride
%rep 8
    movdqa  xmm0, [eax]
    movdqa  xmm1, [eax+ecx]
    lea     eax, [eax+ecx*2]
    movdqa  [edx],    xmm0
    movdqa  [edx+16], xmm1
    add     edx, 32
%endrep
    ret
    
    
; pixel_loadu_16x16_sse2
ALIGN 16
pixel_loadu_16x16_sse2:
    mov edx, [esp+4]    ; dest
    mov eax, [esp+8]    ; src
    mov ecx, [esp+12]   ; stride
%rep 16
    movdqu xmm0, [eax]
    add    eax, ecx
    movdqa [edx], xmm0
    add    edx, 16
%endrep
    ret


; pixel_load_8x8_mmx
ALIGN 16
pixel_load_8x8_mmx:
    mov   edx, [esp+4]      ; dest
    mov   eax, [esp+8]      ; src
    mov   ecx, [esp+12]     ; stride
%rep 4
    movq  mm0, [eax]
    movq  mm1, [eax+ecx]
    lea   eax, [eax+ecx*2]
    movq  [edx],    mm0
    movq  [edx+16], mm1
    add   edx, 32
%endrep
    ret


; procedure pixel_save_16x16_sse2 (src, dest: uint8_p; stride: uint32_t); cdecl;
ALIGN 16
pixel_save_16x16_sse2:
    mov   eax, [esp+4]      ; src
    mov   edx, [esp+8]      ; dest
    mov   ecx, [esp+12]     ; stride
%rep 8
    movdqa  xmm0, [eax]
    movdqa  xmm1, [eax+16]
    add     eax, 32
    movdqa  [edx],     xmm0
    movdqa  [edx+ecx], xmm1
    lea     edx, [edx+ecx*2]
%endrep
    ret


; pixel_save_8x8_mmx
ALIGN 16
pixel_save_8x8_mmx:
    mov   eax, [esp+4]      ; src
    mov   edx, [esp+8]      ; dest
    mov   ecx, [esp+12]     ; stride
%rep 4
    movq  mm0, [eax]
    movq  mm1, [eax+16]
    add     eax, 32
    movq  [edx],     mm0
    movq  [edx+ecx], mm1
    lea     edx, [edx+ecx*2]
%endrep
    ret



; saturated subtraction and 8 -> 16 transport
; procedure pixel_sub_8x8_sse2(pix1, pix2: pbyte; diff: int16_p); cdecl;
ALIGN 16
pixel_sub_4x4_mmx:
    pxor  mm7, mm7
    mov   eax, [esp+ 4]
    mov   edx, [esp+ 8]
    mov   ecx, [esp+12]
%rep 4
    movd      mm0, [eax]
    movd      mm1, [edx]
    punpcklbw mm0, mm7
    punpcklbw mm1, mm7
    psubw     mm0, mm1
    add   eax, 16
    add   edx, 16
    movq      [ecx], mm0
    add   ecx, 8
%endrep
    ret


; saturated addition and 16 -> 8 transport
; procedure pixel_add_8x8_sse2(pix1, pix2: pbyte; diff: int16_p); cdecl;
ALIGN 16
pixel_add_4x4_mmx:
    pxor  mm7, mm7
    mov   edx, [esp+ 4]
    mov   eax, [esp+ 8]
    mov   ecx, [esp+12]
%rep 4
    movd      mm0, [eax]
    movq      mm1, [ecx]
    punpcklbw mm0, mm7
    paddw     mm0, mm1
    add   eax, 16
    add   ecx, 8
    packuswb  mm0, mm7
    movd      [edx], mm0
    add   edx, 16
%endrep
    ret


; procedure pixel_avg_16x16_sse2(src1, src2, dest: uint8_p; stride: integer);
ALIGN 16
pixel_avg_16x16_sse2:
    mov   eax, [esp+4]   ; src1
    mov   edx, [esp+8]   ; src2
    mov   ecx, [esp+12]  ; dest
    push  ebx
    mov   ebx, [esp+20]  ; stride
%rep 16
    movdqu  xmm0, [eax]
    movdqu  xmm1, [edx]
    add     eax, ebx
    add     edx, ebx
    pavgb   xmm0, xmm1
    movdqa  [ecx], xmm0
    add     ecx, 16
%endrep
    pop   ebx
    ret


; ******************************************************************************
; SATD

;subtract two 4x4 blocks, return difference
; 1, 2 - pixel address
; 3 - stride
; 4 - address offset
; output:  m0..m3
; scratch: m5, m7
%macro mSUB4x4 4
    pxor      mm7, mm7
    mov_m2    mm0, [%1 + %4]
    mov_m2    mm5, [%2 + %4]
    punpcklbw mm0, mm7
    punpcklbw mm5, mm7
    mov_m2    mm1, [%1 + 16 + %4]
    mov_m2    mm6, [%2 + %3 + %4]
    punpcklbw mm1, mm7
    punpcklbw mm6, mm7
    psubw     mm0, mm5
    psubw     mm1, mm6

    mov_m2    mm2, [%1 +   32 + %4]
    mov_m2    mm5, [%2 + %3*2 + %4]
    add   %2, %3
    punpcklbw mm2, mm7
    punpcklbw mm5, mm7
    mov_m2    mm3, [%1 +   48 + %4]
    mov_m2    mm6, [%2 + %3*2 + %4]
    punpcklbw mm3, mm7
    punpcklbw mm6, mm7
    psubw     mm2, mm5
    psubw     mm3, mm6
    sub   %2, %3
%endmacro


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


;partially transpose one 4x4 matrix using xmmregs
; out: 2 rows merged in %1 / %3
%macro mTRANSPOSE4_xmm 4
    movdqa  %3, %1
    punpcklwd %1, %2
    punpckhwd %3, %2
    pshufd %1, %1, 216
    pshufd %3, %3, 216
%endmacro

;transpose 2x 4x4 matrix using xmmregs
; in/out: m0..3
; scratch: m5..7
%macro mTRANSPOSE4x2_xmm 0
    movdqa xmm5, xmm0
    movdqa xmm6, xmm1
    movdqa xmm7, xmm2
    
    punpckldq xmm0, xmm2
    punpckldq xmm1, xmm3
    mTRANSPOSE4_xmm xmm0, xmm1, xmm2, xmm3
    punpckhdq xmm5, xmm7
    punpckhdq xmm6, xmm3
    mTRANSPOSE4_xmm xmm5, xmm6, xmm7, xmm3
    
    movdqa xmm1, xmm0 
    punpcklqdq  xmm0, xmm5   ; b|a + b1|a1 -> a1|a  
    punpckhqdq  xmm1, xmm5
    movdqa xmm3, xmm2
    punpcklqdq  xmm2, xmm7
    punpckhqdq  xmm3, xmm7
%endmacro


;hadamard transform for 4x4 matrix
; in/out (in reverse order):  m0..m3
; scratch: m7
%macro mHADAMARD4 0
    mov_m  mm7, mm1
    paddw  mm1, mm3  ; e1 = c + a
    psubw  mm3, mm7  ; e2 = a - c
    mov_m  mm7, mm0
    paddw  mm0, mm2  ; f1 = d + b
    psubw  mm2, mm7  ; f2 = b - d
    mov_m  mm7, mm0
    paddw  mm0, mm1  ; g1 = f1 + e1
    psubw  mm1, mm7  ; g2 = e1 - f1
    mov_m  mm7, mm2
    paddw  mm2, mm3  ; h1 = f2 + e2
    psubw  mm3, mm7  ; h2 = e2 - f2
%endmacro


;absolute value
; 1, 2 - input regs
; scratch: m6, m7
%macro mPABS_2 2
    pxor   mm7, mm7
    pxor   mm6, mm6
    psubw  mm7, %1
    psubw  mm6, %2
    pmaxsw %1, mm7
    pmaxsw %2, mm6
%endmacro


;sum words to 2 doublewords
; in: m0..3
; out: m0
%macro mSUM 0
    mPABS_2 mm0, mm1
    paddw   mm0, mm1
    mPABS_2 mm2, mm3
    paddw   mm2, mm3
    paddw   mm0, mm2
    pmaddwd mm0, [vec_w_8x1]
%endmacro


;sum N dwords, move to result
; scratch: m7
%macro SUM2DW 1
    movq  mm7, %1
    psrlq mm7, 32
    paddd %1, mm7
    movd  eax, %1
%endmacro

%macro SUM4DW 1
    HADDD %1, xmm7
    movd   eax, %1
%endmacro


; SATD mmx
%define mov_m  movq
%define mov_m2 movd

; function satd_4x4_mmx  (pix1, pix2: pbyte; stride: integer): integer; cdecl;
ALIGN 16
satd_4x4_mmx:
    mov   eax, [esp+4]   ; pix1
    mov   edx, [esp+8]   ; pix2
    mov   ecx, [esp+12]  ; stride
    mSUB4x4 eax, edx, ecx, 0
    mHADAMARD4
    mTRANSPOSE4
    mHADAMARD4
    mSUM
    SUM2DW mm0
    ret


; function satd_8x8_mmx  (pix1, pix2: pbyte; stride: integer): integer; cdecl;
ALIGN 16
satd_8x8_mmx:
    mov   eax, [esp+4]   ; pix1
    mov   edx, [esp+8]   ; pix2
    mov   ecx, [esp+12]  ; stride
    push  ebx
    mov   ebx, 2
    pxor  mm4,mm4  ; sum

.loop:
    %assign i 0
    %rep 2
        mSUB4x4 eax, edx, ecx, i
        mHADAMARD4
        mTRANSPOSE4
        mHADAMARD4
        mSUM
        paddd   mm4, mm0
        %assign i i + 4
    %endrep
    lea   eax, [eax + 4 *  16]
    lea   edx, [edx + 4 * ecx]
    dec   ebx
    jnz   .loop

    SUM2DW mm4
    pop   ebx
    ret


; function satd_16x16_mmx  (pix1, pix2: pbyte; stride: integer): integer; cdecl;
ALIGN 16
satd_16x16_mmx:
    mov   eax, [esp+4]   ; pix1
    mov   edx, [esp+8]   ; pix2
    mov   ecx, [esp+12]  ; stride
    push  ebx
    mov   ebx, 4
    pxor  mm4,mm4  ; sum

.loop:
    %assign i 0
    %rep 4
        mSUB4x4 eax, edx, ecx, i
        mHADAMARD4
        mTRANSPOSE4
        mHADAMARD4
        mSUM
        paddd   mm4, mm0
        %assign i i + 4
    %endrep
    lea   eax, [eax + 4 *  16]
    lea   edx, [edx + 4 * ecx]
    dec   ebx
    jnz   .loop

    SUM2DW mm4
    pop   ebx
    ret
    

; SATD sse2
%define mov_m  movdqa
%define mov_m2 movq
%define mm0 xmm0
%define mm1 xmm1
%define mm2 xmm2
%define mm3 xmm3
%define mm4 xmm4
%define mm5 xmm5
%define mm6 xmm6
%define mm7 xmm7

ALIGN 16
satd_16x16_sse2:
    mov   eax, [esp+4]   ; pix1
    mov   edx, [esp+8]   ; pix2
    mov   ecx, [esp+12]  ; stride
    push  ebx
    mov   ebx, 4
    pxor  mm4, mm4  ; sum

.loop:
    %assign i 0
    %rep 2
        mSUB4x4 eax, edx, ecx, i
        mHADAMARD4
        mTRANSPOSE4x2_xmm
        mHADAMARD4
        mSUM
        paddd   mm4, mm0
        %assign i i + 8
    %endrep
    lea   eax, [eax + 4 *  16]
    lea   edx, [edx + 4 * ecx]
    dec   ebx
    jnz   .loop

    SUM4DW mm4
    pop   ebx
    ret

