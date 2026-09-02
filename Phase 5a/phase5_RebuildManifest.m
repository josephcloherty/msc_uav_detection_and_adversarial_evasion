function M = phase5_RebuildManifest(cfg, seedList)
% reconstructs a batch manifest from the feature CSVs and run-info sidecars on
% disk, for when the client died before writing one.

    if nargin < 1 || isempty(cfg), cfg = phase5_Config(); end
    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, 'core', 'functions'));

    if strlength(string(cfg.batch.dataDir)) == 0
        cfg.batch.dataDir = string(fullfile(here, 'data'));
    end
    dataDir = char(cfg.batch.dataDir);

    %% find the runs on disk
    % driven by the files, not by the configured seed range
    files = dir(fullfile(dataDir, 'features_*_seed*.csv'));
    assert(~isempty(files), 'phase5_RebuildManifest:noRuns', ...
        'No features_*_seed*.csv found in %s.', dataDir);

    scen = strings(numel(files), 1);
    seed = nan(numel(files), 1);
    for k = 1:numel(files)
        t = regexp(files(k).name, '^features_(\w+)_seed(\d+)\.csv$', 'tokens', 'once');
        if isempty(t), continue; end
        scen(k) = string(t{1});
        seed(k) = str2double(t{2});
    end
    keep = ~ismissing(scen) & isfinite(seed);
    scen = scen(keep); seed = seed(keep);
    if nargin >= 2 && ~isempty(seedList)
        sel = ismember(seed, seedList(:));
        scen = scen(sel); seed = seed(sel);
    end
    [seed, ord] = sort(seed);
    scen = scen(ord);
    n = numel(seed);

    %% regenerate each run's configuration and metadata
    runCfgs = cell(1, n); metas = cell(1, n); results = cell(1, n);
    nInfo = 0;
    for i = 1:n
        [rc, mt] = phase5_ScenarioGen(cfg, seed(i), scen(i));
        rc.outputDir = string(dataDir);
        runCfgs{i} = rc; metas{i} = mt;

        s = struct('numRows', NaN, 'numCols', NaN, 'hoCountTotal', NaN, ...
            'hoCountAerial', NaN, 'pingPongTotal', NaN, 'wallTime_s', NaN, ...
            'csvPath', string(fullfile(dataDir, char(files(1).name))), ...
            'replayPath', "", 'matlabRelease', "", ...
            'simReached_s', rc.simulationTime, 'truncated', false);
        s.csvPath = string(fullfile(dataDir, ...
            sprintf('features_%s_seed%d.csv', scen(i), seed(i))));
        s.numRows = countRows(char(s.csvPath));

        info = phase5_RunInfo('read', rc);
        if ~isempty(info)
            nInfo = nInfo + 1;
            s = mergeInfo(s, info);
        else
            % no sidecar, but the replay bundle still says whether one
            % was written
            rp = fullfile(dataDir, sprintf('replay_%s_seed%d.mat', ...
                scen(i), seed(i)));
            if exist(rp, 'file') == 2, s.replayPath = string(rp); end
        end
        results{i} = struct('runIdx', i, 'status', "ok", 'summary', s, ...
            'error', "");
    end

    %% assemble and write
    M = buildRebuiltManifest(cfg, runCfgs, metas, results);
    stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
    outPath = fullfile(dataDir, ['manifest_rebuilt_' stamp '.csv']);
    writeCsv(M, outPath);

    fprintf('\nRebuilt manifest for %d run(s) from %s\n', n, dataDir);
    fprintf('  %d run(s) had a run-info sidecar; %d were reconstructed from ', ...
        nInfo, n - nInfo);
    fprintf('their CSV and configuration alone (wall time and handover\n');
    fprintf('  totals are NaN for those: they only exist while the run is live).\n');
    fprintf('  rows total %d\n', sum(M.numRows(isfinite(M.numRows))));
    fprintf('  written to %s\n\n', outPath);

    % fold any recovered wall times into the cost model
    try
        phase5_CostModel('record', cfg, M, NaN);
    catch err
        warning('phase5_RebuildManifest:costRecordFailed', ...
            'Could not record cost measurements: %s', err.message);
    end
end

function s = mergeInfo(s, info)
% prefers the sidecar's values where it has them.
    map = {'numRows', 'numCols', 'hoCountTotal', 'hoCountAerial', ...
        'pingPongTotal', 'wallTime_s', 'simReached_s', 'truncated', ...
        'matlabRelease', 'replayFile', 'poolWorkers'};
    for k = 1:numel(map)
        f = map{k};
        if ~isfield(info, f), continue; end
        v = info.(f);
        if isnumeric(v) && isscalar(v) && isnan(v), continue; end
        switch f
            case 'replayFile', s.replayPath = string(v);
            otherwise,         s.(f) = v;
        end
    end
end

function n = countRows(csvPath)
    n = NaN;
    if exist(csvPath, 'file') ~= 2, return; end
    fid = fopen(csvPath, 'r');
    if fid < 0, return; end
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
    n = 0; sawHeader = false;
    while true
        ln = fgetl(fid);
        if ~ischar(ln), break; end
        if isempty(strtrim(ln)), continue; end
        if ~sawHeader, sawHeader = true; continue; end
        n = n + 1;
    end
end

function M = buildRebuiltManifest(cfg, runCfgs, metas, results)
% builds the same columns as the batch manifest, kept separate on purpose so
% this file keeps working when the runner changes.
    n = numel(runCfgs);
    M = table();
    M.runIdx        = (1:n)';
    M.scenario      = strings(n, 1);
    M.seed          = zeros(n, 1);
    M.status        = strings(n, 1);
    M.simReached_s  = nan(n, 1);
    M.truncated     = nan(n, 1);
    M.numGNB        = zeros(n, 1);
    M.siteRadius_m  = zeros(n, 1);
    M.ueAreaSpan_m  = zeros(n, 1);
    M.numUE         = zeros(n, 1);
    M.numTerrestrial= zeros(n, 1);
    M.numAerial     = zeros(n, 1);
    M.isMultiAerial = zeros(n, 1);
    M.aerialFraction= zeros(n, 1);
    M.anchorLoadMax = zeros(n, 1);
    M.simTime_s     = zeros(n, 1);
    M.windowLen_s   = zeros(n, 1);
    M.windowStride_s= zeros(n, 1);
    M.settleTime_s  = zeros(n, 1);
    M.shadowFading  = zeros(n, 1);
    M.rateJitterFrac= zeros(n, 1);
    M.numRows       = nan(n, 1);
    M.hoCountTotal  = nan(n, 1);
    M.hoCountAerial = nan(n, 1);
    M.pingPongTotal = nan(n, 1);
    M.wallTime_s    = nan(n, 1);
    M.matlabRelease = strings(n, 1);
    M.csvFile       = strings(n, 1);
    M.replayFile    = strings(n, 1);
    M.errorMessage  = strings(n, 1);

    for i = 1:n
        rc = runCfgs{i}; mt = metas{i}; s = results{i}.summary;
        M.scenario(i)       = mt.scenario;
        M.seed(i)           = mt.seed;
        M.status(i)         = results{i}.status;
        M.numGNB(i)         = mt.numGNB;
        M.siteRadius_m(i)   = mt.siteRadius_m;
        M.ueAreaSpan_m(i)   = mt.ueAreaSpan_m;
        M.numUE(i)          = mt.numUE;
        M.numTerrestrial(i) = mt.numTerrestrial;
        M.numAerial(i)      = mt.numAerial;
        M.isMultiAerial(i)  = double(mt.isMultiAerial);
        M.aerialFraction(i) = mt.aerialFraction;
        M.anchorLoadMax(i)  = mt.anchorLoadMax;
        M.simTime_s(i)      = rc.simulationTime;
        M.windowLen_s(i)    = rc.windowLen;
        M.windowStride_s(i) = rc.windowStride;
        M.settleTime_s(i)   = rc.settleTime;
        M.shadowFading(i)   = double(rc.enableShadowFading);
        M.rateJitterFrac(i) = cfg.traffic.rateJitterFrac;
        M.simReached_s(i)   = s.simReached_s;
        M.truncated(i)      = double(s.truncated);
        M.numRows(i)        = s.numRows;
        M.hoCountTotal(i)   = s.hoCountTotal;
        M.hoCountAerial(i)  = s.hoCountAerial;
        M.pingPongTotal(i)  = s.pingPongTotal;
        M.wallTime_s(i)     = s.wallTime_s;
        M.matlabRelease(i)  = string(s.matlabRelease);
        M.csvFile(i)        = s.csvPath;
        M.replayFile(i)     = s.replayPath;
        M.errorMessage(i)   = "";
    end
end

function writeCsv(M, outPath)
% writes the manifest in the same hand-rolled format as the batch.
    fid = fopen(outPath, 'w');
    assert(fid > 0, 'phase5_RebuildManifest:openFailed', ...
        'Could not open %s for writing.', outPath);
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
    names = M.Properties.VariableNames;
    fprintf(fid, '%s\n', strjoin(names, ','));
    % quote character in a variable, for readability
    q = '"';
    for r = 1:height(M)
        parts = cell(1, numel(names));
        for c = 1:numel(names)
            v = M.(names{c})(r);
            if isstring(v) || ischar(v)
                t = char(v);
                if contains(t, ',') || contains(t, q)
                    t = [q, strrep(t, q, [q q]), q];
                end
                parts{c} = t;
            elseif isnan(v)
                parts{c} = 'NaN';
            elseif v == round(v) && abs(v) < 1e12
                parts{c} = sprintf('%d', round(v));
            else
                parts{c} = sprintf('%.6f', v);
            end
        end
        fprintf(fid, '%s\n', strjoin(parts, ','));
    end
end
