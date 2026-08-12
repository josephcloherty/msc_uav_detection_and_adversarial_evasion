@echo off
rem ===================================================================
rem  Phase 5b batch, headless.
rem
rem  Runs phase5b_RunBatch with no MATLAB desktop. This is the right way
rem  to run a batch that lasts days.
rem
rem  The MATLAB desktop and every uifigure are rendered by a Chromium
rem  process, which was killed out of memory late in the Phase 5 24-run
rem  batch on 6 August and took MATLAB with it. With -batch there is no
rem  desktop and no Chromium process, and its memory goes to the workers.
rem
rem  Progress goes to data\batch_status.txt, rewritten every few seconds
rem  with one line per run, and everything printed goes to the log below.
rem  Neither needs MATLAB to be open.
rem
rem  USAGE
rem    run_batch_headless_phase5b.cmd
rem  Closing the window ends the batch. Leave it open, or use "start /b".
rem ===================================================================

setlocal
set PHASEDIR=%~dp0
set LOGDIR=%PHASEDIR%data
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value') do set DT=%%I
set STAMP=%DT:~0,8%_%DT:~8,6%
set LOG=%LOGDIR%\batchlog_phase5b_%STAMP%.txt

echo Phase 5b batch, headless. Log: %LOG%
echo Status board: %LOGDIR%\batch_status.txt
echo.

matlab -batch "cd('%PHASEDIR%'); addpath(genpath(fullfile(pwd,'core'))); phase5b_RunBatch;" -logfile "%LOG%"

echo.
echo Finished with exit code %ERRORLEVEL%. Log: %LOG%
endlocal
