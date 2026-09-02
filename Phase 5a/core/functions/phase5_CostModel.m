function varargout = phase5_CostModel(action, cfg, varargin)
% keeps the measured wall-time constant for the run cost model and returns the
% value implied by finished runs, falling back to the configured prior.

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
% returns the measurements on disk, or an empty table with the right columns.
    T = emptyTable();
    p = storePath(cfg);
    if exist(p, 'file') ~= 2, return; end
    try
        R = readtable(p, 'TextType', 'string');
    catch
        return;   % unreadable store
    end
    need = ["scenario" "seed" "simTime_s" "numGNB" "numUE" "numWorkers" ...
            "wallTime_s" "k"];
    if ~all(ismember(need, string(R.Properties.VariableNames))), return; end

    % readtable retypes columns by release, so coerce them back
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
% appends the completed runs of a manifest to the store.
    if nargin < 3 || isempty(numWorkers), numWorkers = NaN; end
    T = readTable(cfg);

    keep = (manifest.status == "ok" | manifest.status == "salvaged") & ...
        isfinite(manifest.wallTime_s) & manifest.wallTime_s > 0;
    % a truncated run is scaled by the time it actually reached
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
        T = [T; row];   %#ok<AGROW>  one row per run
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

function e = effectiveK(cfg, numWorkers)
% returns the constant to estimate with, and where it came from.
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
        sel = true(height(T), 1);       % any pool size
        e.source = "measured-other-poolsize";
    end
    ks = T.k(sel);
    ks = ks(isfinite(ks) & ks > 0);
    if isempty(ks), e.source = "prior"; return; end

    % median, so one bad run does not drag every estimate
    e.k = median(ks);
    e.n = numel(ks);
    e.spread = [min(ks) max(ks)];
    e.scaleVsPrior = e.k / kP;
end

function w = predictWall(cfg, numGNB, numUE, numWorkers)
% returns the expected wall seconds per run under the effective constant.
    if nargin < 4, numWorkers = NaN; end
    e = effectiveK(cfg, numWorkers);
    simSec = cfg.window.simulationTime;
    w = e.k * simSec * numGNB(:) .* numUE(:);
    w = reshape(w, size(numGNB));
end
