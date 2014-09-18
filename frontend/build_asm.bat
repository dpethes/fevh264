set asm_dir=..\core\asm
yasm -f win32 -dPREFIX -o %asm_dir%\pixel_x86.o       %asm_dir%\pixel_x86.asm
yasm -f win32 -dPREFIX -o %asm_dir%\motion_comp_x86.o %asm_dir%\motion_comp_x86.asm
yasm -f win32 -dPREFIX -o %asm_dir%\frame_x86.o       %asm_dir%\frame_x86.asm
yasm -f win32 -dPREFIX -o %asm_dir%\intra_pred_x86.o  %asm_dir%\intra_pred_x86.asm