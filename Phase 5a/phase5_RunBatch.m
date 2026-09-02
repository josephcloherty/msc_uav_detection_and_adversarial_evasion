function manifest = phase5_RunBatch(cfg)
% enumerates the runs from the configuration, executes them in parallel one per
% worker, and writes a manifest alongside the per-run outputs.

    if nargin < 1 || isempty(cfg)
        cfg = phase5_Config();
    end

    here = fileparts(mfilename('fullpath'));
    fcnDir = fullfile(here, 'core', 'functions');
    addpath(fcnDir);

    %% resolve the output directory
    if strlength(string(cfg.batch.dataDir)) == 0
        cfg.batch.dataDir = string(fullfile(here, 'data'));
    end
    dataDir = char(cfg.batch.dataDir);
    if ~exist(dataDir, 'dir'), mkdir(dataDir); end

    %% the parallel toolbox is mandatory
    assertParallelAvailable();

    %% enumerate the runs
    seeds = cfg.batch.seedRange(:)';
    assert(~isempty(seeds), 'phase5_RunBatch:noSeeds', ...
        'cfg.batch.seedRange is empty.');
    assert(all(seeds == round(seeds)) && all(isfinite(seeds)), ...
        'phase5_RunBatch:nonIntegerSeeds', ...
        'cfg.batch.seedRange must contain finite integers.');
    assert(numel(unique(seeds)) == numel(seeds), ...
        'phase5_RunBatch:duplicateSeeds', ...
        'cfg.batch.seedRange contains duplicates; run identities would collide.');

    cycle = string(cfg.batch.scenarioCycle(:))';
    assert(~isempty(cycle), 'phase5_RunBatch:noScenarios', ...
        'cfg.batch.scenarioCycle is empty.');

    nRuns = min(numel(seeds), cfg.batch.maxRuns);
    seeds = seeds(1:nRuns);
    % scenario comes from the seed value, so trimming or splitting a range
    % leaves every run's identity unchanged
    scenarios = phase5_ScenarioFor(cfg, seeds);

    %% resolve every run configuration up front, so a bad configuration
    % fails before a pool is started
    runCfgs = cell(1, nRuns);
    metas   = cell(1, nRuns);
    for i = 1:nRuns
        [runCfgs{i}, metas{i}] = phase5_ScenarioGen(cfg, seeds(i), scenarios(i));
        runCfgs{i}.outputDir = string(dataDir);
    end

    %% classify the runs already on disk
    % the CSV is written once, after the run finishes, so its presence means
    % the run completed
    todo = true(1, nRuns);
    if cfg.batch.skipExisting
        for i = 1:nRuns
            f = fullfile(dataDir, sprintf('features_%s_seed%d.csv', ...
                scenarios(i), seeds(i)));
            todo(i) = ~isfile(f);
        end
    end

    fprintf('Phase 5 batch: %d run(s) enumerated, %d to execute, %d complete on disk.\n', ...
        nRuns, sum(todo), sum(~todo));
    fprintf('Scenario cycle: %s | seeds %d to %d | output %s\n', ...
        strjoin(cellstr(cycle), ', '), min(seeds), max(seeds), dataDir);

    %% pool
    pool = startPool(cfg);
    fprintf('Parallel pool: %d worker(s).\n', pool.NumWorkers);

    %% size the batch to the pool, one run per worker
    % surplus runs are dropped rather than queued, and the dropped seeds are
    % named so a shorter batch is never silent
    if nRuns > pool.NumWorkers
        dropped = seeds(pool.NumWorkers+1:nRuns);
        fprintf(['Trimming batch to the pool: %d run(s) enumerated but only ' ...
            '%d worker(s).\n'], nRuns, pool.NumWorkers);
        fprintf(['  Dropped seed(s): %s. Nothing is queued, so these are not ' ...
            'run at all. Re-run with cfg.batch.seedRange set to them, or ' ...
            'raise cfg.batch.numWorkers to match.\n'], ...
            strjoin(string(dropped), ', '));
        nRuns     = pool.NumWorkers;
        seeds     = seeds(1:nRuns);
        scenarios = scenarios(1:nRuns);
        runCfgs   = runCfgs(1:nRuns);
        metas     = metas(1:nRuns);
        todo      = todo(1:nRuns);
    elseif nRuns < pool.NumWorkers
        fprintf(['Note: %d run(s) on %d worker(s); %d worker(s) will sit ' ...
            'idle. Match cfg.batch.seedRange to cfg.batch.numWorkers to use ' ...
            'the whole pool.\n'], nRuns, pool.NumWorkers, ...
            pool.NumWorkers - nRuns);
    end

    %% progress reporting from the workers
    % the reporter lives on the client and is mutated by the afterEach
    % callback, which parfor services while it waits
    labels = "" + scenarios + " seed " + string(seeds);
    useProgress = cfg.progress.enable;

    % cost-model prior per run, so there is an estimate before any run has
    % reported
    nGNBv = cellfun(@(m) m.numGNB, metas);
    nUEv  = cellfun(@(m) m.numUE,  metas);
    kInfo = phase5_CostModel('effective', cfg, pool.NumWorkers);
    priorWall = kInfo.k * cfg.window.simulationTime * nGNBv .* nUEv;
    reportCostModel(kInfo, priorWall, todo, pool.NumWorkers);

    % the status file goes next to the data unless given its own path
    pcfg = cfg.progress;
    if isfield(pcfg, 'statusFile') && strlength(string(pcfg.statusFile)) > 0
        sf = char(pcfg.statusFile);
        if isempty(fileparts(sf))
            pcfg.statusFile = string(fullfile(dataDir, sf));
        end
        fprintf('Status board: %s\n', pcfg.statusFile);
    end

    prog = phase5_Progress(labels, pcfg, ...
        struct('priorWall_s', priorWall, 'numWorkers', pool.NumWorkers));
    progGuard = onCleanup(@() prog.close());   % close on error too
    prog.markSkipped(~todo);

    q = parallel.pool.DataQueue;
    afterEach(q, @(msg) prog.update(msg));
    batchStart = tic;

    %% execute
    % one iteration per worker, dispatched in seed order, so they all start
    % together and results is indexed directly by run
    fprintf('Dispatch: %d run(s) on %d worker(s), all starting together.\n', ...
        nRuns, pool.NumWorkers);
    % that holds only while the two numbers match; a smaller pool makes the
    % surplus runs queue under parfor's default partitioning
    if pool.NumWorkers < sum(todo)
        fprintf(['Note: %d run(s) to execute on %d worker(s), so %d will ' ...
            'queue. parfor assigns its subranges up front, so a worker may ' ...
            'hold a queued run while another is idle.\n'], sum(todo), ...
            pool.NumWorkers, sum(todo) - pool.NumWorkers);
    end
    nWorkersUsed = pool.NumWorkers;
    results = cell(1, nRuns);
    continueOnError = cfg.batch.continueOnError;
    parfor (i = 1:nRuns, pool.NumWorkers)
        addpath(fcnDir);   % workers do not inherit the path
        rc = runCfgs{i};
        rc.poolWorkers = nWorkersUsed;   % into this run's sidecar
        if useProgress
            rc.progressQueue = q;
            rc.runIdx = i;
        end
        rec = struct('status', "skipped", 'summary', [], 'error', "");
        if todo(i)
            try
                rec.summary = phase5_Pipeline(rc);
                rec.status  = "ok";
            catch err
                rec.status = "failed";
                rec.error  = string(err.message);
                if ~continueOnError
                    rethrow(err);
                end
            end
            % the wall time travels with the completion message so the cost
            % model can be recalibrated during the batch
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
    clear progGuard;   % close the progress bar

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
    % every finished run measures this machine at this pool size
    phase5_CostModel('record', cfg, manifest, pool.NumWorkers);
    kAfter = phase5_CostModel('effective', cfg, pool.NumWorkers);
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
        fprintf('Merge the per-run CSVs with: phase5_MergeDataset\n');
    end
end

function reportCostModel(kInfo, priorWall, todo, nWorkers)
% prints the cost basis and the projection before the batch runs.
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

function pool = startPool(cfg)
% opens the parallel pool, trying each client port range in turn and only then
% stepping the worker count down.
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

    % oversubscription is legal but not free: the runs are CPU bound
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
    % the range in force when the batch started
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
                    % raise the profile ceiling if it is below the request,
                    % wrapped so a read-only property does not consume the attempt
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

    error('phase5_RunBatch:poolStartFailed', ...
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

function ranges = portCandidates(cfg)
% returns the client listening ranges to try, in order: as shipped, ephemeral,
% then two high fixed ranges.
    ranges = {[], 0, [40000 41000], [21000 22000]};
    if isfield(cfg.batch, 'poolPortRanges') && ~isempty(cfg.batch.poolPortRanges)
        ranges = cfg.batch.poolPortRanges;
        if ~iscell(ranges), ranges = {ranges}; end
    end
end

function applyPortRange(r, origRange)
% sets the client port range for the next pool start. failure is reported and
% not fatal, so an unusable range falls through to the next candidate.
    if isempty(r)
        r = origRange;                 % restore the session setting
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

function clearStalePool()
% removes the state a failed pool start leaves behind. everything is wrapped,
% because a cleanup that throws would mask the original error.
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

function assertParallelAvailable()
% errors when parfor cannot run in parallel, rather than falling back to serial
% and looking like a hang.
    hasLicence = license('test', 'Distrib_Computing_Toolbox');
    hasInstall = ~isempty(ver('parallel'));
    if ~(hasLicence && hasInstall)
        error('phase5_RunBatch:noParallelToolbox', ...
            ['The Parallel Computing Toolbox is required (licence: %d, ' ...
             'installed: %d). Install or license it, or run a single ' ...
             'scenario directly with phase5_Pipeline(phase5_ScenarioGen(' ...
             'phase5_Config, seed, "UMa")).'], hasLicence, hasInstall);
    end
end

function M = buildManifest(cfg, runCfgs, metas, results)
% builds one manifest row per run, recording the generation parameters.
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
            % skipped or failed: name the CSV the run would have written
            M.csvFile(i) = string(fullfile(char(rc.outputDir), ...
                sprintf('features_%s_seed%d.csv', rc.scenario, rc.seed)));
        end
    end
end

function writeManifest(M, outPath)
% writes the manifest by hand rather than with writetable, so the quoting and
% number formatting are explicit.
    fid = fopen(outPath, 'w');
    assert(fid > 0, 'phase5_RunBatch:manifestOpenFailed', ...
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
% wraps a text field in quotes when it needs it.
    q = '"';
    s = strrep(s, sprintf('\n'), ' ');
    s = strrep(s, sprintf('\r'), ' ');
    if contains(s, ',') || contains(s, q)
        s = [q, strrep(s, q, [q q]), q];
    end
end
