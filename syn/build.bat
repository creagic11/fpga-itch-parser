@echo off
rem Windows: run the Vivado batch flow.  syn\build.bat [TOP] [PART]
rem Run from the repository root, e.g.  C:\...\fpga-itch-parser> syn\build.bat
setlocal
where vivado >nul 2>nul
if errorlevel 1 (
  if exist "C:\Xilinx\Vivado\2024.1\settings64.bat" (
    call "C:\Xilinx\Vivado\2024.1\settings64.bat"
  ) else (
    echo Vivado not found. Edit the settings64.bat path in syn\build.bat to match your install.
    exit /b 1
  )
)
call vivado -mode batch -nojournal -nolog -source syn/build.tcl -tclargs %*
endlocal
