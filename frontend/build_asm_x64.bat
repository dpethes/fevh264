set asm_dir=..\core\asm_x64
yasm -f win64 -o %asm_dir%\pixel_x64.o %asm_dir%\pixel_x64.asm
yasm -f win64 -o %asm_dir%\motion_comp_x64.o %asm_dir%\motion_comp_x64.asm
yasm -f win64 -o %asm_dir%\frame_x64.o %asm_dir%\frame_x64.asm
yasm -f win64 -o %asm_dir%\intra_pred_x64.o %asm_dir%\intra_pred_x64.asm

