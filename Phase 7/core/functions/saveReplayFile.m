function outPath = saveReplayFile(cfg, posLog, gNBs, UEs, managers, extras)
%saveReplayFile Write a reloadable replay bundle without opening the viewer.
%
%   OUTPATH = saveReplayFile(CFG, POSLOG, GNBS, UES, MANAGERS, EXTRAS)
%   writes <dataDir>/replay_<scenario>_seed<seed>.mat holding the same
%   replayData structure that the interactive replay's "Save Replay..."
%   button produces, so the file reopens with
%
%       replayScenario('replay_UMa_seed7.mat')
%       phase5_ReplayRun("UMa", 7)
%
%   The batch runner cannot open the interactive viewer, since the runs
%   execute on parallel workers with no display, so the bundle is written
%   directly instead. POSLOG is stored UN-CULLED: replayScenario re-culls
%   the settle span on load, which keeps the saved file independent of
%   the settle and cull settings in force at generation time.
%
%   CFG.replay fields used:
%     .format        save format string, "-v7.3" by default (needed above
%                    the 2 GB v7 limit; a 30 s seven-cell run with the
%                    scheduler and measurement logs attached is tens of
%                    megabytes)
%     .includeNodes  false stores empty node arrays, which drops the
%                    largest objects in the bundle at the cost of the
%                    node markers in the replay. The position log,
%                    feature logs and handover history are kept either
%                    way, so the statistics panel still works.
%
%   The buildings field is written as an empty 0-by-6 matrix: the Phase 5
%   scenarios carry no explicit building geometry (the UMa building
%   height enters through the TR 36.777 ZOD offset, not as an object).

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
