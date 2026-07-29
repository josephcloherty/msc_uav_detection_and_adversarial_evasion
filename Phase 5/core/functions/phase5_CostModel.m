function varargout = phase5_CostModel(action, cfg, varargin)
%phase5_CostModel Measured wall-time cost model for run and batch estimation.
%
%   The cost of a run is modelled as
%       wall_s = k * simulatedSeconds * numGNB * numUE
%   because the expense is dominated by per-packet channel filtering across
%   the UE-to-gNB links and by every UE's SRS being received at every gNB,
%   both of which scale with that product. k is a single constant per
%   machine and pool size.
%
%   The constant in phase5_Config is only a PRIOR. It was calibrated from
%   6 s smoke runs at 7 gNB and 3 UE, where the fixed per-run overheads are
%   a large fraction of a short run, and it underestimated the real dataset
%   runs by more than a factor of two. This helper keeps the measurements
%   from finished runs on disk and returns the value they imply, so every
%   later estimate is made from this machine's own numbers rather than from
%   a projection made before any full run existed.
%
%   POOL SIZE MATTERS
%   k is measured under contention: six runs sharing six cores cost more
%   per run than one run alone. Every measurement therefore records the
%   pool size it was made at, and 'effective' prefers measurements taken at
%   the pool size being asked about, falling back to all of them with the
%   mismatch reported. Without that, a k measured on six workers would
%   silently under-predict a twelve worker batch on the same machine.
%
%   ACTIONS
%     phase5_CostModel('record', cfg, manifest, numWorkers)
%         Append one row per completed run in MANIFEST (ok or salvaged,
%         finite wall time). Existing rows for the same scenario, seed and
%         pool size are replaced, so re-running a seed re-calibrates
%         rather than double counting.
%     e = phase5_CostModel('effective', cfg, numWorkers)
%         Struct: k, n (measurements used), atWorkers, source
%         ("measured" | "measured-other-poolsize" | "prior"), kPrior,
%         scaleVsPrior, spread (min and max of the k used).
%     w = phase5_CostModel('predict', cfg, numGNB, numUE, numWorkers)
%         Expected wall seconds per run, elementwise over numGNB/numUE.
%     T = phase5_CostModel('table', cfg)
%         The measurement table, empty if none.
%
%   The file is data/costmodel_measured.csv, plain text so it can be read
%   and corrected by hand, and it is never required: every action falls
%   back to the configured prior when it is missing.

    switch string(action)
        case "record"
            varargout{1} = recordRuns(cfg, varargin{:});
        case "effective"
            varargout{1} = effectiveK(cfg, varargin{:});
        case "predict"
            varargout{1} = predictWall(cfg, varargin{:});
        case "table"
            varargout{1} = readTable(cfg);
        otherwise
            error('phase5_CostModel:unknownAction', ...
                'Unknown action "%s".', action);
    end
end

%% ----------------------------------------------------------------------
function p = storePath(cfg)
    if isfield(cfg, 'batch') && isfield(cfg.batch, 'dataDir') && ...
            strlength(string(cfg.batch.dataDir)) > 0
        d = char(cfg.batch.dataDir);
    else
        d = fullfile(fileparts(mfilename('fullpath')), '..', '..', 'data');
    end
    p = fullfile(d, 'costmodel_measured.csv');
end

%% ----------------------------------------------------------------------
function k = priorK(cfg)
    k = 14.9;
    if isfield(cfg, 'batch') && isfield(cfg.batch, 'costModel') && ...
            isfield(cfg.batch.costModel, 'sPerSimSecPerGNBPerUE')
        k = cfg.batch.costModel.sPerSimSecPerGNBPerUE;
    end
end

%% ----------------------------------------------------------------------
function T = readTable(cfg)
%readTable Measurements on disk, or an empty table with the right columns.
    T = emptyTable();
    p = storePath(cfg);
    if exist(p, 'file') ~= 2, return; end
    try
        R = readtable(p, 'TextType', 'string');
    catch
        return;   % unreadable store is treated as no store
    end
    need = ["scenario" "seed" "simTime_s" "numGNB" "numUE" "numWorkers" ...
            "wallTime_s" "k"];
    if ~all(ismember(need, string(R.Properties.VariableNames))), return; end

    % readtable will happily turn the timestamp column into datetime and the
    % scenario column into cellstr depending on release and content, and
    % either breaks the vertcat that appends a new row. Coerced back to the
    % types emptyTable declares.
    if ~isstring(R.scenario), R.scenario = string(R.scenario); end
    if ismember('recordedOn', R.Properties.VariableNames)
        R.recordedOn = string(R.recordedOn);
    else
        R.recordedOn = strings(height(R), 1);
    end
    T = R;
end

function T = emptyTable()
    T = table(strings(0,1), zeros(0,1), zeros(0,1), zeros(0,1), zeros(0,1), ...
        zeros(0,1), zeros(0,1), zeros(0,1), strings(0,1), ...
        'VariableNames', {'scenario', 'seed', 'simTime_s', 'numGNB', ...
        'numUE', 'numWorkers', 'wallTime_s', 'k', 'recordedOn'});
end

%% ----------------------------------------------------------------------
function T = recordRuns(cfg, manifest, numWorkers)
%recordRuns Append the completed runs of a manifest to the store.
    if nargin < 3 || isempty(numWorkers), numWorkers = NaN; end
    T = readTable(cfg);

    keep = (manifest.status == "ok" | manifest.status == "salvaged") & ...
        isfinite(manifest.wallTime_s) & manifest.wallTime_s > 0;
    % A truncated run took less simulated time than the manifest's nominal
    % length, so its cost is divided by what it actually reached.
    idx = find(keep)';
    stamp = string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    for i = idx
        simSec = manifest.simTime_s(i);
        if ismember('simReached_s', manifest.Properties.VariableNames) && ...
                isfinite(manifest.simReached_s(i)) && manifest.simReached_s(i) > 0
            simSec = manifest.simReached_s(i);
        end
        denom = simSec * manifest.numGNB(i) * manifest.numUE(i);
        if ~isfinite(denom) || denom <= 0, continue; end

        row = table(manifest.scenario(i), manifest.seed(i), simSec, ...
            manifest.numGNB(i), manifest.numUE(i), numWorkers, ...
            manifest.wallTime_s(i), manifest.wallTime_s(i)/denom, stamp, ...
            'VariableNames', T.Properties.VariableNames);

        dup = T.scenario == manifest.scenario(i) & T.seed == manifest.seed(i) & ...
            (T.numWorkers == numWorkers | (isnan(T.numWorkers) & isnan(numWorkers)));
        T(dup, :) = [];
        T = [T; row];   %#ok<AGROW>  one row per completed run, batch-sized
    end

    if isempty(idx), return; end
    try
        writetable(T, storePath(cfg));
    catch err
        warning('phase5_CostModel:writeFailed', ...
            'Could not write %s (%s). The measurements are not persisted.', ...
            storePath(cfg), err.message);
    end
end

%% ----------------------------------------------------------------------
function e = effectiveK(cfg, numWorkers)
%effectiveK The constant to estimate with, and where it came from.
    if nargin < 2, numWorkers = NaN; end
    kP = priorK(cfg);
    e = struct('k', kP, 'n', 0, 'atWorkers', numWorkers, 'source', "prior", ...
        'kPrior', kP, 'scaleVsPrior', 1, 'spread', [NaN NaN]);

    T = readTable(cfg);
    if isempty(T), return; end

    sel = false(height(T), 1);
    if ~isnan(numWorkers)
        sel = T.numWorkers == numWorkers;
    end
    if any(sel)
        e.source = "measured";
    else
        sel = true(height(T), 1);       % any pool size is better than a guess
        e.source = "measured-other-poolsize";
    end
    ks = T.k(sel);
    ks = ks(isfinite(ks) & ks > 0);
    if isempty(ks), e.source = "prior"; return; end

    % Median, not mean: one run that hit a swap storm or a laptop thermal
    % limit should not drag every later estimate with it.
    e.k = median(ks);
    e.n = numel(ks);
    e.spread = [min(ks) max(ks)];
    e.scaleVsPrior = e.k / kP;
end

%% ----------------------------------------------------------------------
function w = predictWall(cfg, numGNB, numUE, numWorkers)
%predictWall Expected wall seconds per run under the effective constant.
    if nargin < 4, numWorkers = NaN; end
    e = effectiveK(cfg, numWorkers);
    simSec = cfg.window.simulationTime;
    w = e.k * simSec * numGNB(:) .* numUE(:);
    w = reshape(w, size(numGNB));
end
