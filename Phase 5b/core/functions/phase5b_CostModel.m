function varargout = phase5b_CostModel(action, cfg, varargin)
%phase5b_CostModel Measured wall-time cost model for run and batch estimation.
%
%   A run costs roughly
%       wall_s = k * simulatedSeconds * numGNB * numUE
%
%   The constant in phase5b_Config is a prior; measurements from finished runs
%   are kept on disk and preferred. k is measured under contention, so every
%   measurement records its pool size and 'effective' prefers ones taken at
%   the size being asked about.
%
%   Actions:
%     phase5b_CostModel('record', cfg, manifest, numWorkers)
%         Append one row per completed run; a repeated scenario/seed/pool
%         replaces its old row rather than double counting.
%     e = phase5b_CostModel('effective', cfg, numWorkers)
%         Struct with k, n, atWorkers, source, kPrior, scaleVsPrior, spread.
%     w = phase5b_CostModel('predict', cfg, numGNB, numUE, numWorkers)
%         Expected wall seconds per run.
%     T = phase5b_CostModel('table', cfg)
%         The measurement table, empty if none.
%
%   The store is data/costmodel_measured.csv, plain text and safe to edit by
%   hand. Every action falls back to the prior when it is missing.

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
            error('phase5b_CostModel:unknownAction', ...
                'Unknown action "%s".', action);
    end
end

function p = storePath(cfg)
    if isfield(cfg, 'batch') && isfield(cfg.batch, 'dataDir') && ...
            strlength(string(cfg.batch.dataDir)) > 0
        d = char(cfg.batch.dataDir);
    else
        d = fullfile(fileparts(mfilename('fullpath')), '..', '..', 'data');
    end
    p = fullfile(d, 'costmodel_measured.csv');
end

function k = priorK(cfg)
    k = 14.9;
    if isfield(cfg, 'batch') && isfield(cfg.batch, 'costModel') && ...
            isfield(cfg.batch.costModel, 'sPerSimSecPerGNBPerUE')
        k = cfg.batch.costModel.sPerSimSecPerGNBPerUE;
    end
end

function T = readTable(cfg)
%readTable Measurements on disk, or an empty table with the right columns.
    T = emptyTable();
    p = storePath(cfg);
    if exist(p, 'file') ~= 2, return; end
    try
        R = readtable(p, 'TextType', 'string');
    catch
        return;   % an unreadable store is treated as no store
    end
    need = ["scenario" "seed" "simTime_s" "numGNB" "numUE" "numWorkers" ...
            "wallTime_s" "k"];
    if ~all(ismember(need, string(R.Properties.VariableNames))), return; end
    % readtable types these differently by release and content, which breaks
    % the vertcat that appends a new row.
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

function T = recordRuns(cfg, manifest, numWorkers)
%recordRuns Append the completed runs of a manifest to the store.
    if nargin < 3 || isempty(numWorkers), numWorkers = NaN; end
    T = readTable(cfg);

    keep = (manifest.status == "ok" | manifest.status == "salvaged") & ...
        isfinite(manifest.wallTime_s) & manifest.wallTime_s > 0;
    % A truncated run's cost is divided by the time it actually reached.
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
        warning('phase5b_CostModel:writeFailed', ...
            'Could not write %s (%s). The measurements are not persisted.', ...
            storePath(cfg), err.message);
    end
end

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
        sel = true(height(T), 1);   % any pool size beats a guess
        e.source = "measured-other-poolsize";
    end
    ks = T.k(sel);
    ks = ks(isfinite(ks) & ks > 0);
    if isempty(ks), e.source = "prior"; return; end

    % Median, not mean, so one thermally throttled run does not drag every
    % later estimate with it.
    e.k = median(ks);
    e.n = numel(ks);
    e.spread = [min(ks) max(ks)];
    e.scaleVsPrior = e.k / kP;
end

function w = predictWall(cfg, numGNB, numUE, numWorkers)
%predictWall Expected wall seconds per run under the effective constant.
    if nargin < 4, numWorkers = NaN; end
    e = effectiveK(cfg, numWorkers);
    simSec = cfg.window.simulationTime;
    w = e.k * simSec * numGNB(:) .* numUE(:);
    w = reshape(w, size(numGNB));
end
