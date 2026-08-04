function manifest = phase7_RunBatch(cfg)
%phase7_RunBatch Run the whole batch in parallel and write a manifest.
%
%   manifest = phase7_RunBatch()      uses phase7_Config()
%   manifest = phase7_RunBatch(CFG)   uses a modified configuration
%
%   This is the only script you need to run. Progress goes to the command
%   window.
%
%   Run i uses seed cfg.batch.seedRange(i) and scenario
%   cfg.batch.scenarioCycle(mod(i-1, nCycle)+1). Because a run is identified
%   by (scenario, seed), you can split a seed range across machines.
%
%   Writes into cfg.batch.dataDir (default <Phase 7>/data):
%     features_<scenario>_seed<seed>.csv   labelled feature rows
%     replay_<scenario>_seed<seed>.mat     replay bundle, if enabled
%     manifest_<tag>.csv                   one row per run
%
%   Run phase7_DryRun first to see the dataset shape without simulating.
%   Merge the per-run CSVs afterwards with phase7_MergeDataset.
%
%   Needs the Parallel Computing Toolbox; missing it is a hard error rather
%   than a silent fall back to serial.
%
%   Safe to re-run: finished runs are skipped, so a batch that lost some of
%   its runs is completed by launching it again.

    if nargin < 1 || isempty(cfg)
        cfg = phase7_Config();
    end

    here = fileparts(mfilename('fullpath'));
    fcnDir = fullfile(here, 'core', 'functions');
    addpath(fcnDir);

    %% resolve output directory
    if strlength(string(cfg.batch.dataDir)) == 0
        cfg.batch.dataDir = string(fullfile(here, 'data'));
    end
    dataDir = char(cfg.batch.dataDir);
    if ~exist(dataDir, 'dir'), mkdir(dataDir); end

    %% parallel toolbox is mandatory
    assertParallelAvailable();

    %% enumerate runs
    seeds = cfg.batch.seedRange(:)';
    assert(~isempty(seeds), 'phase7_RunBatch:noSeeds', ...
        'cfg.batch.seedRange is empty.');
    assert(all(seeds == round(seeds)) && all(isfinite(seeds)), ...
        'phase7_RunBatch:nonIntegerSeeds', ...
        'cfg.batch.seedRange must contain finite integers.');
    assert(numel(unique(seeds)) == numel(seeds), ...
        'phase7_RunBatch:duplicateSeeds', ...
        'cfg.batch.seedRange contains duplicates; run identities would collide.');

    cycle = string(cfg.batch.scenarioCycle(:))';
    assert(~isempty(cycle), 'phase7_RunBatch:noScenarios', ...
        'cfg.batch.scenarioCycle is empty.');

    nRuns = min(numel(seeds), cfg.batch.maxRuns);
    seeds = seeds(1:nRuns);
    scenarios = cycle(mod((0:nRuns-1), numel(cycle)) + 1);

    %% resolve every run configuration up front
    % Doing this on the client catches a bad config before a pool is started.
    runCfgs = cell(1, nRuns);
    metas   = cell(1, nRuns);
    for i = 1:nRuns
        [runCfgs{i}, metas{i}] = phase7_ScenarioGen(cfg, seeds(i), scenarios(i));
        runCfgs{i}.outputDir = string(dataDir);
    end

    %% classify runs already on disk
    % The CSV is written once, after run() returns, so its presence means the
    % run finished.
    todo = true(1, nRuns);
    if cfg.batch.skipExisting
        for i = 1:nRuns
            f = fullfile(dataDir, sprintf('features_%s_seed%d.csv', ...
                scenarios(i), seeds(i)));
            todo(i) = ~isfile(f);
        end
    end

    fprintf('Phase 7 batch: %d run(s) enumerated, %d to execute, %d complete on disk.\n', ...
        nRuns, sum(todo), sum(~todo));
    fprintf('Scenario cycle: %s | seeds %d to %d | output %s\n', ...
        strjoin(cellstr(cycle), ', '), min(seeds), max(seeds), dataDir);

    %% pool
    pool = startPool(cfg);
    fprintf('Parallel pool: %d worker(s).\n', pool.NumWorkers);

    %% progress reporting from the workers
    % parfor services the afterEach callback while it waits, so the reporter
    % keeps printing for the whole batch.
    labels = "" + scenarios + " seed " + string(seeds);
    useProgress = cfg.progress.enable;

    % The reporter needs a cost estimate for runs that have not started yet,
    % or the ETA comes out around half the truth.
    nGNBv = cellfun(@(m) m.numGNB, metas);
    nUEv  = cellfun(@(m) m.numUE,  metas);
    kInfo = phase7_CostModel('effective', cfg, pool.NumWorkers);
    priorWall = kInfo.k * cfg.window.simulationTime * nGNBv .* nUEv;
    reportCostModel(kInfo, priorWall, todo, pool.NumWorkers);

    prog = phase7_Progress(labels, cfg.progress, ...
        struct('priorWall_s', priorWall, 'numWorkers', pool.NumWorkers));
    prog.markSkipped(~todo);

    q = parallel.pool.DataQueue;
    afterEach(q, @(msg) prog.update(msg));
    batchStart = tic;

    %% execute
    results = cell(1, nRuns);
    continueOnError = cfg.batch.continueOnError;
    parfor i = 1:nRuns
        addpath(fcnDir);   % workers do not inherit the client path
        rc = runCfgs{i};
        if useProgress
            rc.progressQueue = q;
            rc.runIdx = i;
        end
        rec = struct('status', "skipped", 'summary', [], 'error', "");
        if todo(i)
            try
                rec.summary = phase7_Pipeline(rc);
                rec.status  = "ok";
            catch err
                rec.status = "failed";
                rec.error  = string(err.message);
                if ~continueOnError
                    rethrow(err);
                end
            end
            % Send the measured wall time so the client can recalibrate the
            % cost model mid-batch.
            wallDone = NaN;
            if isstruct(rec.summary) && isfield(rec.summary, 'wallTime_s')
                wallDone = rec.summary.wallTime_s;
            end
            send(q, struct('kind', "done", 'run', i, 'status', rec.status, ...
                'wall', wallDone));
        end
        results{i} = rec;
    end
    batchWall = toc(batchStart);
    prog.finish();     % DONE block: every run accounted for

    %% manifest
    manifest = buildManifest(cfg, runCfgs, metas, results);
    if strlength(string(cfg.batch.tag)) == 0
        tag = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
    else
        tag = char(cfg.batch.tag);
    end
    manifestPath = fullfile(dataDir, ['manifest_' tag '.csv']);
    writeManifest(manifest, manifestPath);

    %% cost model recalibration
    % Record every finished run so the next batch estimates from measured
    % cost instead of the configured prior.
    phase7_CostModel('record', cfg, manifest, pool.NumWorkers);
    kAfter = phase7_CostModel('effective', cfg, pool.NumWorkers);
    if kAfter.n > 0
        fprintf(['Cost model: %.1f s per (sim-s x gNB x UE) from %d run(s) ' ...
            'at %d worker(s), spread %.1f to %.1f.\n'], kAfter.k, kAfter.n, ...
            pool.NumWorkers, kAfter.spread(1), kAfter.spread(2));
        if abs(kAfter.scaleVsPrior - 1) > 0.1
            fprintf(['  That is %.2fx the configured prior of %.1f. Set ' ...
                'cfg.batch.costModel.sPerSimSecPerGNBPerUE = %.1f to make ' ...
                'the projection match, or leave it: measurements on disk ' ...
                'already take precedence.\n'], kAfter.scaleVsPrior, ...
                kAfter.kPrior, kAfter.k);
        end
    end

    %% summary
    nOK   = sum(manifest.status == "ok");
    nSkip = sum(manifest.status == "skipped");
    nFail = sum(manifest.status == "failed");
    fprintf('\nBatch complete in %s: %d ok, %d skipped, %d failed.\n', ...
        fmtDuration(batchWall), nOK, nSkip, nFail);
    fprintf('Manifest: %s\n', manifestPath);
    if nFail > 0
        fprintf('Failed runs:\n');
        bad = find(manifest.status == "failed")';
        for k = bad
            fprintf('  %s seed %d: %s\n', manifest.scenario(k), ...
                manifest.seed(k), manifest.errorMessage(k));
        end
        fprintf(['Re-run this script to retry them: the finished runs are ' ...
            'skipped.\n']);
    end
    if nOK > 0
        fprintf('Merge the per-run CSVs with: phase7_MergeDataset\n');
    end
end

%% ------------------------------------------------------------------------
function reportCostModel(kInfo, priorWall, todo, nWorkers)
%reportCostModel Print the cost basis and the projection before the batch runs.
    switch kInfo.source
        case "measured"
            src = sprintf('measured from %d run(s) at %d worker(s)', ...
                kInfo.n, nWorkers);
        case "measured-other-poolsize"
            src = sprintf(['measured from %d run(s) at a DIFFERENT pool ' ...
                'size; cost per run rises with contention, so treat this ' ...
                'as a lower bound'], kInfo.n);
        otherwise
            src = 'configured prior, no measurements on disk yet';
    end
    w = priorWall(todo);
    if isempty(w), return; end
    fprintf('Cost basis: %.1f s per (sim-s x gNB x UE) (%s).\n', kInfo.k, src);
    fprintf('  projected %s to %s per run, %s of CPU time over %d run(s).\n', ...
        fmtDuration(min(w)), fmtDuration(max(w)), fmtDuration(sum(w)), numel(w));
end

%% ------------------------------------------------------------------------
function pool = startPool(cfg)
%startPool Open the pool, retrying the failures a long batch hits.
%
%   The client binds a listening port from 27370 up, and that bind fails for
%   reasons outside this project. The usual symptom is:
%       Timed out opening port localhost:27370
%
%   Recovery order:
%     1. Try each port range via pctconfig, since a blocked port is not a
%        capacity problem.
%     2. Clear stale cluster jobs and retry.
%     3. Halve the worker count and repeat.
%   If none of that works the error names what to check.
    pool = gcp('nocreate');
    if ~isempty(pool)
        fprintf('Reusing the open pool (%d worker(s)).\n', pool.NumWorkers);
        return;
    end

    want = cfg.batch.numWorkers;
    if isempty(want)
        c = parcluster('Processes');
        want = c.NumWorkers;
    end
    want = max(round(want(1)), 1);

    retries = 2; backoff = 15;
    if isfield(cfg.batch, 'poolRetries'), retries = max(cfg.batch.poolRetries, 0); end
    if isfield(cfg.batch, 'poolRetryWait_s'), backoff = max(cfg.batch.poolRetryWait_s, 0); end
    allowFewer = true;
    if isfield(cfg.batch, 'allowFewerWorkers')
        allowFewer = cfg.batch.allowFewerWorkers;
    end

    % The runs are CPU bound, so doubling workers on the same cores roughly
    % doubles the wall time per run.
    nPhysical = feature('numcores');
    if want > nPhysical
        fprintf(['Note: %d workers requested on %d physical core(s). Runs ' ...
            'are CPU bound, so each will take longer in proportion; total ' ...
            'throughput gains little beyond one worker per core.\n'], ...
            want, nPhysical);
    end

    sizes = want;
    if allowFewer
        step = want;
        while step > 1
            step = max(floor(step/2), 1);
            sizes(end+1) = step; %#ok<AGROW>
        end
        sizes = unique(sizes, 'stable');
    end

    ranges = portCandidates(cfg);
    % Remember the starting range so the "leave as configured" candidate
    % means that, not whatever a failed attempt set.
    origRange = [];
    try
        pc = pctconfig();
        if isfield(pc, 'portrange'), origRange = pc.portrange; end
    catch
    end

    lastErr = [];
    for s = sizes
        for r = 1:numel(ranges)
            applyPortRange(ranges{r}, origRange);
            for attempt = 0:retries
                try
                    c = parcluster('Processes');
                    % Raise the profile's ceiling if it is below the
                    % request, wrapped so an unwritable property does not
                    % consume the attempt.
                    try
                        if c.NumWorkers < s, c.NumWorkers = s; end
                    catch
                    end
                    pool = parpool(c, s);
                    if s < want
                        fprintf(['Pool opened with %d worker(s) instead of ' ...
                            '%d after start failures.\n'], s, want);
                    end
                    if r > 1
                        fprintf(['Pool opened on port range %s. Add ' ...
                            'pctconfig(''portrange'', %s) to startup.m to ' ...
                            'skip the failed attempts next time.\n'], ...
                            rangeText(ranges{r}), rangeText(ranges{r}));
                    end
                    return;
                catch err
                    lastErr = err;
                    fprintf(['Pool start failed at %d worker(s), ports %s, ' ...
                        'attempt %d of %d: %s\n'], s, ...
                        rangeText(ranges{r}), attempt+1, retries+1, err.message);
                    clearStalePool();
                    if attempt < retries && backoff > 0
                        fprintf('  retrying in %g s...\n', backoff);
                        pause(backoff);
                    end
                end
            end
        end
    end

    error('phase7_RunBatch:poolStartFailed', ...
        ['Could not start a parallel pool at any worker count or port range ' ...
         '(last error: %s).\n' ...
         'The client binds a listening port for the interactive pool, by ' ...
         'default from 27370 up. If jobs work but the pool does not, the ' ...
         'port is the problem. Check, in this order:\n' ...
         '  1. Reserved port blocks. Run, in a command prompt:\n' ...
         '       netsh int ipv4 show excludedportrange protocol=tcp\n' ...
         '     Hyper-V, WSL and Docker reserve wide ranges at boot, and a ' ...
         'port inside one cannot be bound even with nothing listening on it. ' ...
         'If a reserved range covers the port, either move the range with ' ...
         'pctconfig (already attempted here) or free it: net stop winnat, ' ...
         'then netsh int ipv4 add excludedportrange protocol=tcp ' ...
         'startport=27370 numberofports=1010, then net start winnat.\n' ...
         '  2. Orphaned workers from an earlier session. Look for ' ...
         'MATLABWorker (or MATLAB) processes in Task Manager with no window ' ...
         'and end them, then restart MATLAB.\n' ...
         '  3. Stale job metadata. Close MATLAB and delete the ' ...
         'local_cluster_jobs folder under %%LOCALAPPDATA%%\\MathWorks\\MATLAB' ...
         '\\R20xx\\.\n' ...
         '  4. Firewall or security software blocking loopback TCP for ' ...
         'MATLAB; the pool needs sockets between client and workers.\n' ...
         '  5. Hostname resolution: the machine must resolve its own name ' ...
         'to its own address.\n' ...
         'Nothing is lost by fixing this and re-running: whole runs are the ' ...
         'unit of work and finished runs are skipped.'], lastErr.message);
end

%% ------------------------------------------------------------------------
function ranges = portCandidates(cfg)
%portCandidates Client listening ranges to try, in order.
%   [] keeps the configured range, 0 asks for ephemeral ports, and a
%   two-element vector is an explicit range.
    ranges = {[], 0, [40000 41000], [21000 22000]};
    if isfield(cfg.batch, 'poolPortRanges') && ~isempty(cfg.batch.poolPortRanges)
        ranges = cfg.batch.poolPortRanges;
        if ~iscell(ranges), ranges = {ranges}; end
    end
end

function applyPortRange(r, origRange)
%applyPortRange Set the client port range for the next pool start.
%   Failure is reported but not fatal, so an unusable range falls through to
%   the next candidate.
    if isempty(r)
        r = origRange;                 % restore the session's own setting
        if isempty(r), return; end
    end
    try
        pctconfig('portrange', r);
    catch err
        fprintf('  could not set port range %s (%s).\n', rangeText(r), ...
            err.message);
    end
end

function t = rangeText(r)
    if isempty(r)
        t = 'default';
    elseif isscalar(r) && r == 0
        t = 'ephemeral';
    else
        t = sprintf('[%d %d]', r(1), r(end));
    end
end

%% ------------------------------------------------------------------------
function clearStalePool()
%clearStalePool Best-effort removal of the state a failed start leaves behind.
%   A half-opened pool keeps its ports, so a retry without this usually fails
%   the same way.
    try
        p = gcp('nocreate');
        if ~isempty(p), delete(p); end
    catch
    end
    try
        c = parcluster('Processes');
        j = c.Jobs;
        if ~isempty(j), delete(j); end
    catch
    end
end

%% ------------------------------------------------------------------------
function assertParallelAvailable()
%assertParallelAvailable Hard error if parfor cannot run in parallel.
%   Deliberately not a fall back to serial, which would look like a hang.
    hasLicence = license('test', 'Distrib_Computing_Toolbox');
    hasInstall = ~isempty(ver('parallel'));
    if ~(hasLicence && hasInstall)
        error('phase7_RunBatch:noParallelToolbox', ...
            ['The Parallel Computing Toolbox is required (licence: %d, ' ...
             'installed: %d). Install or license it, or run a single ' ...
             'scenario directly with phase7_Pipeline(phase7_ScenarioGen(' ...
             'phase7_Config, seed, "UMa")).'], hasLicence, hasInstall);
    end
end

%% ------------------------------------------------------------------------
function M = buildManifest(cfg, runCfgs, metas, results)
%buildManifest One row per run, recording the generation parameters.
%   simReached_s and truncated stay in the column set because
%   phase7_CostModel divides the wall time by them.
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
        rc = runCfgs{i}; mt = metas{i}; rs = results{i};
        M.scenario(i)       = mt.scenario;
        M.seed(i)           = mt.seed;
        M.status(i)         = rs.status;
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
        M.matlabRelease(i)  = string(version('-release'));
        M.errorMessage(i)   = rs.error;
        if ~isempty(rs.summary)
            s = rs.summary;
            M.numRows(i)       = s.numRows;
            M.hoCountTotal(i)  = s.hoCountTotal;
            M.hoCountAerial(i) = s.hoCountAerial;
            M.pingPongTotal(i) = s.pingPongTotal;
            M.wallTime_s(i)    = s.wallTime_s;
            M.csvFile(i)       = s.csvPath;
            M.replayFile(i)    = s.replayPath;
            M.matlabRelease(i) = s.matlabRelease;
            if isfield(s, 'simReached_s'), M.simReached_s(i) = s.simReached_s; end
            if isfield(s, 'truncated'),    M.truncated(i) = double(s.truncated); end
        else
            % Skipped or failed, so just name the CSV the run would have
            % written.
            M.csvFile(i) = string(fullfile(char(rc.outputDir), ...
                sprintf('features_%s_seed%d.csv', rc.scenario, rc.seed)));
        end
    end
end

%% ------------------------------------------------------------------------
function writeManifest(M, outPath)
%writeManifest Plain comma-separated manifest with quoted text fields.
%   Written by hand so the quoting is explicit and the formatting does not
%   vary with the release.
    fid = fopen(outPath, 'w');
    assert(fid > 0, 'phase7_RunBatch:manifestOpenFailed', ...
        'Could not open %s for writing.', outPath);
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>

    names = M.Properties.VariableNames;
    fprintf(fid, '%s\n', strjoin(names, ','));
    for r = 1:height(M)
        parts = cell(1, numel(names));
        for c = 1:numel(names)
            v = M.(names{c})(r);
            if isstring(v) || ischar(v)
                parts{c} = quoteField(char(v));
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

function s = quoteField(s)
%quoteField Wrap a text field in quotes when it needs it.
%   The quote character sits in a variable because a literal one next to a
%   closing bracket reads ambiguously against MATLAB's transpose syntax.
    q = '"';
    s = strrep(s, sprintf('\n'), ' ');
    s = strrep(s, sprintf('\r'), ' ');
    if contains(s, ',') || contains(s, q)
        s = [q, strrep(s, q, [q q]), q];
    end
end
