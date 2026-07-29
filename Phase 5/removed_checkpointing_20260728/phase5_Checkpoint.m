function varargout = phase5_Checkpoint(action, cfg, varargin)
%phase5_Checkpoint Per-run checkpoint bookkeeping for resumable batches (D5.1).
%
%   A single simulation run is long enough (hours) that an overnight
%   machine shutdown can cut one off partway. This helper lets the
%   pipeline write its feature CSV incrementally, in simulated-time
%   segments, and records how far each run got, so that an interrupted
%   batch resumes without losing or recomputing completed work.
%
%   WHAT IS AND IS NOT POSSIBLE
%   --------------------------
%   The feature rows are salvageable because every 10 s window that has
%   finished is a valid, self-contained row: rewriting the CSV after each
%   segment means the file on disk always holds every window simulated so
%   far. Truly continuing the SAME simulation from a saved point is not:
%   wirelessNetworkSimulator is a singleton with live event scheduling and
%   addlistener connections that do not survive save/load into a runnable
%   state, and a silently-broken resume would corrupt the dataset. So an
%   interrupted run is not re-simulated from the middle; instead its
%   completed rows are kept (salvage) or the whole run is redone from the
%   start (restart), per cfg.checkpoint.resumeMode.
%
%   ARTEFACTS (in <outputDir>/checkpoints)
%     <scenario>_seed<seed>.ckpt.mat   small marker: simReached, complete,
%                                      truncated, salvaged, numRows,
%                                      everySimSeconds, wallSoFar
%   The feature CSV itself (written by writeFeatureCSV to <outputDir>) is
%   the salvage output; the marker only records completion state beside it.
%
%   TRUTHFULNESS OF THE MARKER
%   simReached is the simulated time the run actually got to and is never
%   overwritten with the nominal length. A salvaged run is therefore
%   recorded as complete (nothing more will be attempted) AND truncated
%   (it is shorter than cfg.window.simulationTime), so the batch, the
%   manifest and any later audit can tell a full run from a short one.
%   Writing simReached = simulationTime on salvage, as an earlier version
%   did, destroyed the only evidence that a run was cut off.
%
%   ACTIONS
%     phase5_Checkpoint('paths', cfg)            -> struct of paths
%     phase5_Checkpoint('status', cfg)           -> "complete"|"partial"|"fresh"
%     phase5_Checkpoint('read', cfg)             -> marker struct or []
%     phase5_Checkpoint('write', cfg, simReached, complete, nRows, wall)
%     phase5_Checkpoint('salvage', cfg, nRows)   -> mark done, keep simReached
%     phase5_Checkpoint('info', cfg)             -> struct with defaulted
%                                                   fields, safe on an old
%                                                   or missing marker
%     phase5_Checkpoint('clearState', cfg)       -> remove heavy state (none kept)
%
%   The marker is written with a temp-file-and-rename so an interruption
%   during the write cannot leave a half-written marker that misreports
%   completion.

    switch string(action)
        case "paths"
            varargout{1} = resolvePaths(cfg);
        case "status"
            varargout{1} = runStatus(cfg);
        case "read"
            varargout{1} = readMarker(cfg);
        case "write"
            writeMarker(cfg, varargin{:});
        case "salvage"
            varargout{1} = salvageMarker(cfg, varargin{:});
        case "info"
            varargout{1} = markerInfo(cfg);
        case "clearState"
            clearState(cfg);
        otherwise
            error('phase5_Checkpoint:unknownAction', ...
                'Unknown action "%s".', action);
    end
end

%% ----------------------------------------------------------------------
function p = resolvePaths(cfg)
%resolvePaths Marker path, derived to sit beside the run's feature CSV.
    if isfield(cfg, 'outputDir') && strlength(string(cfg.outputDir)) > 0
        outDir = char(cfg.outputDir);
    else
        outDir = fullfile(fileparts(mfilename('fullpath')), '..', '..', 'data');
    end
    stem = sprintf('%s_seed%d', string(cfg.scenario), cfg.seed);
    p = struct();
    p.outDir    = outDir;
    p.csv       = fullfile(outDir, sprintf('features_%s.csv', stem));
    p.ckptDir   = fullfile(outDir, 'checkpoints');
    p.marker    = fullfile(p.ckptDir, [stem '.ckpt.mat']);
end

%% ----------------------------------------------------------------------
function m = readMarker(cfg)
%readMarker Return the marker struct, or [] if none exists or it is unreadable.
    p = resolvePaths(cfg);
    m = [];
    if exist(p.marker, 'file') ~= 2, return; end
    try
        S = load(p.marker, 'marker');
        m = S.marker;
    catch
        m = [];   % unreadable marker is treated as no marker
    end
end

%% ----------------------------------------------------------------------
function marker = writeMarker(cfg, simReached, complete, nRows, wall, salvaged)
%writeMarker Atomically write the completion marker beside the CSV.
%   truncated is derived, not passed: a run is truncated exactly when it is
%   being closed out (complete) at less than its configured length. Deriving
%   it here means no caller can mark a short run as a full one.
    if nargin < 5, wall = NaN; end
    if nargin < 6, salvaged = false; end
    p = resolvePaths(cfg);
    if ~exist(p.ckptDir, 'dir'), mkdir(p.ckptDir); end

    simTotal  = cfg.simulationTime;
    complete  = logical(complete);
    truncated = complete && simReached < simTotal - 1e-9;

    marker = struct('scenario', string(cfg.scenario), 'seed', cfg.seed, ...
        'simReached', simReached, 'simTotal', simTotal, ...
        'complete', complete, 'truncated', truncated, ...
        'salvaged', logical(salvaged), 'numRows', nRows, ...
        'everySimSeconds', getEvery(cfg), 'wallSoFar_s', wall, ...
        'savedOn', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')));

    tmp = [p.marker '.tmp'];
    save(tmp, 'marker');
    movefile(tmp, p.marker, 'f');   % rename is the atomic step
end

%% ----------------------------------------------------------------------
function marker = salvageMarker(cfg, nRows)
%salvageMarker Close out an interrupted run without inflating simReached.
%   The simulated time already reached is read back from the existing
%   marker and written again unchanged; only the completion state changes.
%   If the previous marker is missing or unreadable the reached time is
%   unknown, and NaN is recorded rather than a guess, which still reads as
%   truncated because NaN < simTotal is false but the salvaged flag is set.
    prev = readMarker(cfg);
    if isempty(prev) || ~isfield(prev, 'simReached')
        reached = NaN;
    else
        reached = prev.simReached;
    end
    wall = NaN;
    if ~isempty(prev) && isfield(prev, 'wallSoFar_s')
        wall = prev.wallSoFar_s;
    end
    marker = writeMarker(cfg, reached, true, nRows, wall, true);
    % NaN reached: not provably full length, so record it as truncated.
    if isnan(reached) && ~marker.truncated
        marker.truncated = true;
        p = resolvePaths(cfg);
        tmp = [p.marker '.tmp'];
        save(tmp, 'marker');
        movefile(tmp, p.marker, 'f');
    end
end

%% ----------------------------------------------------------------------
function info = markerInfo(cfg)
%markerInfo Marker fields with defaults, safe on a missing or older marker.
%   Markers written before the truncated/salvaged fields existed are read
%   without error; their missing flags default to false, and callers that
%   need to distrust an old marker use simReached against simTotal.
    m = readMarker(cfg);
    info = struct('exists', ~isempty(m), 'scenario', string(cfg.scenario), ...
        'seed', cfg.seed, 'simReached', NaN, ...
        'simTotal', cfg.simulationTime, 'complete', false, ...
        'truncated', false, 'salvaged', false, 'numRows', NaN, ...
        'wallSoFar_s', NaN, 'savedOn', "");
    if isempty(m), return; end
    fields = {'simReached', 'simTotal', 'complete', 'truncated', ...
              'salvaged', 'numRows', 'wallSoFar_s', 'savedOn'};
    for k = 1:numel(fields)
        f = fields{k};
        if isfield(m, f), info.(f) = m.(f); end
    end
    info.complete  = logical(info.complete);
    info.truncated = logical(info.truncated) || ...
        (info.complete && info.simReached < info.simTotal - 1e-9);
end

%% ----------------------------------------------------------------------
function s = runStatus(cfg)
%runStatus Classify a run from its marker and CSV.
%   "complete" marker says the run finished; "partial" a marker exists but
%   is not complete (interrupted); "fresh" nothing usable on disk.
    p = resolvePaths(cfg);
    m = readMarker(cfg);
    if ~isempty(m) && m.complete && exist(p.csv, 'file') == 2
        s = "complete";
    elseif ~isempty(m) && exist(p.csv, 'file') == 2
        s = "partial";
    else
        s = "fresh";
    end
end

%% ----------------------------------------------------------------------
function clearState(cfg) %#ok<INUSD>
%clearState Placeholder: no heavy live-simulator state file is kept.
%   Live-simulator snapshots are deliberately not written (see the file
%   header), so there is nothing to remove on completion. Kept as an
%   action so callers do not need to know that.
end

%% ----------------------------------------------------------------------
function e = getEvery(cfg)
    e = 5;
    if isfield(cfg, 'checkpoint') && isfield(cfg.checkpoint, 'everySimSeconds')
        e = cfg.checkpoint.everySimSeconds;
    end
end
