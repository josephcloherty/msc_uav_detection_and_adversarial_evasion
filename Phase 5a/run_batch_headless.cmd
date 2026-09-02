@echo off
rem ===================================================================
rem  Phase 5 batch, headless.
rem
rem  Runs phase5_RunBatch with no MATLAB desktop. This is the right way
rem  to run a batch that lasts days.
rem
rem  WHY
rem  The MATLAB desktop and every uifigure are rendered by a Chromium
rem  process. On 6 August that process was killed out of memory late in
rem  a 24-run batch (crash handler: TS_PROCESS_OOM) and took MATLAB with
rem  it, losing one in-flight run and the manifest for the twenty-three
rem  that had already finished. With -batch there is no desktop and no
rem  Chromium process, so that failure cannot happen, and its memory is
rem  available to the workers instead.
rem
rem  WATCHING IT
rem  Progress goes to data\batch_status.txt, rewritten every few seconds
rem  with one line per run, and everything printed goes to the log file
rem  below. Neither needs MATLAB to be open.
rem
rem  USAGE
rem    run_batch_headless.cmd
rem  Close the window to leave it running? No: closing the window ends
rem  the batch. Leave it open, or start it with "start /b".
rem ===================================================================

setlocal
set PHASE5=%~dp0
set LOGDIR=%PHASE5%data
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value') do set DT=%%I
set STAMP=%DT:~0,8%_%DT:~8,6%
set LOG=%LOGDIR%\batchlog_%STAMP%.txt

echo Phase 5 batch, headless. Log: %LOG%
echo Status board: %LOGDIR%\batch_status.txt
echo.

matlab -batch "cd('%PHASE5%'); addpath(genpath(fullfile(pwd,'core'))); phase5_RunBatch;" -logfile "%LOG%"

echo.
echo Finished with exit code %ERRORLEVEL%. Log: %LOG%
endlocal
