@echo off
setlocal
if defined GODOT_EXE goto configured
if exist "%~dp0tools\godot-4.7.2\Godot_v4.7.2-stable_win64.exe" goto bundled
where godot >nul 2>&1
if not errorlevel 1 goto on_path
echo Godot 4.7.2 was not found. Set GODOT_EXE to the full executable path,
echo or import game/project.godot from the Godot project manager.
exit /b 1

:configured
if not exist "%GODOT_EXE%" goto invalid_path
start "Sheep - Godot" "%GODOT_EXE%" --path "%~dp0game" --editor
exit /b 0

:bundled
start "Sheep - Godot" "%~dp0tools\godot-4.7.2\Godot_v4.7.2-stable_win64.exe" --path "%~dp0game" --editor
exit /b 0

:on_path
start "Sheep - Godot" godot --path "%~dp0game" --editor
exit /b 0

:invalid_path
echo GODOT_EXE does not point to an existing executable.
exit /b 1
