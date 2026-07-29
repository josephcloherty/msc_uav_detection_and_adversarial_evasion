function s = fmtDuration(secs)
%fmtDuration Human-readable duration string.
%
%   S = fmtDuration(SECS) formats a number of seconds as '42 s',
%   '7 min 13 s' or '1 h 04 min 09 s'. Non-finite input returns '--',
%   which is what an ETA reads before enough progress has accumulated to
%   estimate one.
%
%   Promoted from a local function in phase3_Pipeline/phase4_Pipeline to
%   a shared file for Phase 5, because the batch runner and the progress
%   reporter both need it and neither is inside the pipeline.

    if ~isfinite(secs)
        s = '--';
        return;
    end
    secs = max(secs, 0);
    if secs < 60
        s = sprintf('%.0f s', secs);
    elseif secs < 3600
        s = sprintf('%d min %02.0f s', floor(secs/60), mod(secs, 60));
    else
        s = sprintf('%d h %02d min %02.0f s', floor(secs/3600), ...
            floor(mod(secs, 3600)/60), mod(secs, 60));
    end
end
