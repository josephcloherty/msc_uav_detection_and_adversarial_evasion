function outPath = saveReplayFile(cfg, posLog, gNBs, UEs, managers, extras)
%saveReplayFile Write a reloadable replay bundle without opening the viewer.
%
%   OUTPATH = saveReplayFile(CFG, POSLOG, GNBS, UES, MANAGERS, EXTRAS) writes
%   <dataDir>/replay_<scenario>_seed<seed>.mat in the same format the
%   replay's "Save Replay..." button produces, so it reopens with
%
%       replayScenario('replay_UMa_seed7.mat')
%       phase7_ReplayRun("UMa", 7)
%
%   Workers have no display, so the bundle is written directly rather than
%   through the viewer. POSLOG is stored un-culled and replayScenario
%   re-culls on load.
%
%   CFG.replay fields used:
%     .format        save format, "-v7.3" by default; these bundles run past
%                    the 2 GB v7 limit
%     .includeNodes  false drops the node objects and their markers but
%                    keeps the logs the statistics panel needs
%
%   buildings is written empty; these scenarios carry no building geometry.

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
        'posLog',    posLog, ...        % un-culled: reload re-culls once
        'gNBs',      gNBsOut, ...
        'UEs',       UEsOut, ...
        'managers',  {managers}, ...    % cell wrapped to keep as one field
        'buildings', zeros(0, 6), ...
        'extras',    extras, ...        % cfg + linkInfo for the channel panel
        'savedOn',   char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'))); %#ok<NASGU>

    fmt = '-v7.3';
    if isfield(cfg.replay, 'format') && strlength(string(cfg.replay.format)) > 0
        fmt = char(cfg.replay.format);
    end
    save(outPath, 'replayData', fmt);
end
