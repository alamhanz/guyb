@echo off
rem guyb on PATH for cmd.exe, Win+R and any shell: runs the launcher in pwsh (or Windows PowerShell).
where pwsh >nul 2>&1 && (set "guyb_ps=pwsh") || (set "guyb_ps=powershell")
where %guyb_ps% >nul 2>&1 || (echo guyb: neither pwsh nor powershell found on PATH 1>&2 & exit /b 1)
%guyb_ps% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0guyb.ps1" %*
exit /b %ERRORLEVEL%
