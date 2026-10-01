@echo off
REM Launch the tracker (a console window flashes briefly, then hides).
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0TimeTracker.ps1" %*
