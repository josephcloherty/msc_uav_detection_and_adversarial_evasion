function s = fmtDuration(secs)
%fmtDuration Human-readable duration string.
%
%   S = fmtDuration(SECS) gives '42 s', '7 min 13 s' or '1 h 04 min 09 s'.
%   Non-finite input returns '--', which is what an ETA reads early on.

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
