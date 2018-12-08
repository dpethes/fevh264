set asm_dir=..\core\asm_x64
set current_dir=..\..\frontend
set asm=yasm
cd %asm_dir%
%asm% -f win64 -o pixel_x64.o pixel_x64.asm
%asm% -f win64 -o motion_comp_x64.o motion_comp_x64.asm
%asm% -f win64 -o frame_x64.o frame_x64.asm
%asm% -f win64 -o intra_pred_x64.o intra_pred_x64.asm
%asm% -f win64 -o transquant_x64.o transquant_x64.asm
cd %current_dir%
