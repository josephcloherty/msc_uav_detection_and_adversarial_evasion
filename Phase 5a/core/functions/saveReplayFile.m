function outPath = saveReplayFile(cfg, posLog, gNBs, UEs, managers, extras)
% writes a reloadable replay bundle to disk without opening the viewer, for
% batch runs on workers with no display.

    if isfield(cfg, 'outputDir') && ~isempty(cfg.outputDir) && ...
            strlength(string(cfg.outputDir)) > 0
        outDir = char(cfg.outputDir);
    else
        outDir = fullfile(fileparts(mfilename('fullpath')), '..', '..', 'data');
    end
    if ~exist(outDir, 'dir'), mkdir(outDir); end

    outPath = fullfile(outDir, sprintf('replay_%s_seed%d.mat', ...
        string(cfg.scenario), cfg.seed));

    if isfield(cfg.replay, 'includeNodes') && ~cfg.replay.includeNodes
        gNBsOut = []; UEsOut = [];
    else
        gNBsOut = gNBs; UEsOut = UEs;
    end

    replayData = struct( ...
        'posLog',    posLog, ...        % un-culled
        'gNBs',      gNBsOut, ...
        'UEs',       UEsOut, ...
        'managers',  {managers}, ...    % cell wrapped
        'buildings', zeros(0, 6), ...
        'extras',    extras, ...        % cfg and linkInfo
        'savedOn',   char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'))); %#ok<NASGU>

    fmt = '-v7.3';
    if isfield(cfg.replay, 'format') && strlength(string(cfg.replay.format)) > 0
        fmt = char(cfg.replay.format);
    end
    save(outPath, 'replayData', fmt);
end
