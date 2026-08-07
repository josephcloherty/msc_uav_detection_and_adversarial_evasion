function manifest = phase5_RunBatch(cfg)
%phase5_RunBatch Parallel batch runner for the Phase 5 dataset (D5.1).
%
%   manifest = phase5_RunBatch()      uses phase5_Config()
%   manifest = phase5_RunBatch(CFG)   uses a modified configuration
%
%   This is the only script that needs running. It enumerates the runs
%   from cfg.batch, generates one seeded scenario per run, executes them
%   in parallel, and writes a manifest recording every generation
%   parameter alongside the per-run outputs.
%
%   RUN ENUMERATION
%     run i  ->  seed     = cfg.batch.seedRange(i)
%                scenario = cfg.batch.scenarioCycle(mod(i-1, nCycle)+1)
%   so numel(cfg.batch.seedRange) runs are produced, with the scenarios
%   cycled one per run. Because the run identity is (scenario, seed) and
%   both come from the configuration, a seed range can be split across
%   machines with no coordination and the outputs merge without conflict.
%
%   OUTPUTS (all in cfg.batch.dataDir, default <Phase 5>/data)
%     features_<scenario>_seed<seed>.csv   labelled feature rows
%     replay_<scenario>_seed<seed>.mat     replay bundle, if enabled
%     manifest_<tag>.csv                   one row per run
%
%   Run phase5_DryRun first to see the dataset shape without simulating,
%   and phase5_SmokeCheck to verify each scenario end to end on a short
%   run. Concatenate the per-run CSVs into a single dataset with
%   phase5_MergeDataset. Reopen any run's replay with
%   phase5_ReplayRun(scenario, seed).
%
%   PARALLELISM
%   Runs execute under parfor. Each worker is a separate process with its
%   own wirelessNetworkSimulator singleton, so runs do not interfere. The
%   Parallel Computing Toolbox is required and its absence is a hard
%   error rather than a silent fall back to serial execution, so a batch
%   never quietly takes many times longer than expected.
%
%   ONE RUN PER WORKER, NO QUEUE
%   The batch is sized to the pool: the number of runs executed is capped
%   at pool.NumWorkers, so every run starts immediately and none waits on
%   another. Set cfg.batch.seedRange and cfg.batch.numWorkers to the same
%   length. If the pool comes up smaller than the seed range - because
%   cfg.batch.allowFewerWorkers let it step down after a failed launch -
%   the trailing seeds are dropped and named on the console rather than
%   queued behind the others; re-run to pick them up on a later batch.
%
%   There is deliberately no dispatch queue. A queue means some run does
%   not begin until another finishes, which is the failure mode this
%   design removes: with runs of thirty hours a single run left to start
%   last extends the batch by its own length, and a run that fails to be
%   dispatched is indistinguishable from one that is merely waiting.
%
%   RE-RUNNING A BATCH
%   With cfg.batch.skipExisting true a run whose feature CSV already exists
%   is skipped, so a batch that lost some of its runs is completed by
%   re-running this script: whole runs are the unit of work. A run that did
%   not finish leaves no CSV and is simply run again from the start. With
%   cfg.batch.continueOnError true a failed run is recorded in the manifest
%   and the batch carries on.

    if nargin < 1 || isempty(cfg)
        cfg = phase5_Config();
    end

    here = fileparts(mfilename('fullpath'));
    fcnDir = fullfile(here, 'core', 'functions');
    addpath(fcnDir);

    %% ---- resolve output directory ------------------------------------
    if strlength(string(cfg.batch.dataDir)) == 0
        cfg.batch.dataDir = string(fullfile(here, 'data'));
    end
    dataDir = char(cfg.batch.dataDir);
    if ~exist(dataDir, 'dir'), mkdir(dataDir); end

    %% ---- parallel toolbox is mandatory --------------------------------
    assertParallelAvailable();

    %% ---- enumerate runs ------------------------------------------------
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
    scenarios = cycle(mod((0:nRuns-1), numel(cycle)) + 1);

    %% ---- resolve every run configuration up front -----------------------
    % Generating on the client fails fast on a bad configuration (SRS
    % capacity, altitude below the overlay floor, run shorter than a
    % window) before a pool is started, and gives the manifest its
    % population figures even for skipped or failed runs.
    runCfgs = cell(1, nRuns);
    metas   = cell(1, nRuns);
    for i = 1:nRuns
        [runCfgs{i}, metas{i}] = phase5_ScenarioGen(cfg, seeds(i), scenarios(i));
        runCfgs{i}.outputDir = string(dataDir);
    end

    %% ---- classify runs already on disk -----------------------------------
    % A run whose feature CSV exists is complete: the CSV is written once,
    % after run() returns, so its presence means the run finished. There is
    % no partial state to classify now that checkpointing has been removed,
    % and a run interrupted before it finished simply leaves nothing behind
    % and is enumerated again.
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

    %% ---- pool ---------------------------------------------------------------
    pool = startPool(cfg);
    fprintf('Parallel pool: %d worker(s).\n', pool.NumWorkers);

    %% ---- size the batch to the pool: one run per worker -----------------------
    % Every enumerated run must be able to start at once. Runs beyond the
    % worker count would have to wait for a worker to free up, and waiting is
    % what this design removes, so they are dropped here rather than queued.
    % The dropped seeds are named because a silently shorter batch is a
    % dataset with missing seeds that only shows up in the merge.
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

    %% ---- progress reporting from the workers ---------------------------------
    % phase5_Progress lives on the client and is mutated by the afterEach
    % callback, which parfor services while it waits, so the readout keeps
    % moving throughout the batch. Workers report their own simulated-time
    % fraction periodically as well as completion, so overall progress is
    % a mean over the running simulations rather than a count of finished
    % ones. Without that a batch of long runs would sit at zero per cent,
    % with no estimated time remaining, until the first worker returned.
    labels = "" + scenarios + " seed " + string(seeds);
    useProgress = cfg.progress.enable;

    % Cost-model prior for every run, measured from this machine's finished
    % runs where any exist. The reporter needs an estimate before any run has
    % reported: for the opening minutes of a batch every run sits near zero
    % per cent, and a mean-percentage extrapolation over that reports a
    % finish time with no relation to the truth.
    nGNBv = cellfun(@(m) m.numGNB, metas);
    nUEv  = cellfun(@(m) m.numUE,  metas);
    kInfo = phase5_CostModel('effective', cfg, pool.NumWorkers);
    priorWall = kInfo.k * cfg.window.simulationTime * nGNBv .* nUEv;
    reportCostModel(kInfo, priorWall, todo, pool.NumWorkers);

    % The status file goes next to the data unless it was given a path of its
    % own, so a headless batch leaves its readout with its output.
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
    progGuard = onCleanup(@() prog.close());   % close the bar on error too
    prog.markSkipped(~todo);

    q = parallel.pool.DataQueue;
    afterEach(q, @(msg) prog.update(msg));
    batchStart = tic;

    %% ---- execute --------------------------------------------------------------
    % One iteration per worker, dispatched in seed order. There is no queue
    % and no dispatch ordering to choose: with nRuns == pool.NumWorkers every
    % partitioning parfor could pick gives each worker exactly one run, so
    % they all start together and results is indexed directly by run.
    fprintf('Dispatch: %d run(s) on %d worker(s), all starting together.\n', ...
        nRuns, pool.NumWorkers);
    % That claim holds only while the two numbers match. startPool reduces
    % the worker count when a pool will not open at the requested size, and
    % a smaller pool means the surplus runs queue under parfor's default
    % partitioning, which assigns subranges up front rather than one run at a
    % time. Said out loud rather than left as a surprise in the wall times.
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
        addpath(fcnDir);   % workers do not inherit the client path
        rc = runCfgs{i};
        rc.poolWorkers = nWorkersUsed;   % goes into this run's own sidecar
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
            % The measured wall time travels with the completion message so
            % the client can recalibrate the cost model during the batch
            % rather than only after every run has finished.
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
    clear progGuard;   % batch finished: close the progress bar

    %% ---- manifest -------------------------------------------------------------
    manifest = buildManifest(cfg, runCfgs, metas, results);
    if strlength(string(cfg.batch.tag)) == 0
        tag = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
    else
        tag = char(cfg.batch.tag);
    end
    manifestPath = fullfile(dataDir, ['manifest_' tag '.csv']);
    writeManifest(manifest, manifestPath);

    %% ---- cost model recalibration ----------------------------------------------
    % Every finished run is a measurement of this machine at this pool size.
    % Recording them means the next dry run and the next batch's ETA both
    % start from measured cost instead of from the smoke run projection,
    % which underestimated the real runs by more than 2x.
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

    %% ---- summary ---------------------------------------------------------------
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

%% ==========================================================================
function reportCostModel(kInfo, priorWall, todo, nWorkers)
%reportCostModel State the cost basis and the projection before the batch runs.
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

%% ==========================================================================
function pool = startPool(cfg)
%startPool Open the pool, surviving the failures a long batch actually hits.
%
%   parpool on the Processes profile starts one worker process per worker and
%   connects to each over a localhost port from the range 27370 upward. That
%   handshake fails for reasons that have nothing to do with this project:
%   worker processes orphaned by a previous MATLAB session still holding the
%   port, a firewall or security product blocking loopback sockets, stale
%   job metadata in the local cluster job storage, or a machine too loaded to
%   complete twelve handshakes inside the timeout. The symptom is
%       Timed out opening port localhost:27370
%   which is what killed the 12-worker launch on 28 July.
%
%   THE PORT RANGE IS THE FIRST THING TO CHANGE
%   Validating the Processes profile on 28 July passed every stage that uses
%   jobs, including a communicating job on twelve workers, and failed only on
%   the interactive pool, at the client's own bind:
%       parallel.internal.pool.SpfClientSession ...
%       Timed out opening port localhost:27370
%   Jobs working while the interactive pool cannot bind means the machine, not
%   the toolbox, is refusing that port. On Windows the usual reason is a
%   reserved exclusion block: Hyper-V, WSL and Docker reserve wide swathes of
%   TCP ports at boot, and anything inside a reserved range cannot be bound
%   even though nothing is listening on it. Check with
%       netsh int ipv4 show excludedportrange protocol=tcp
%   The fix in code is pctconfig, which moves the client's listening range;
%   portrange 0 asks for ephemeral ports and so cannot collide with a fixed
%   reservation at all. Each candidate range is tried in turn before the
%   worker count is touched, because a blocked port is not a capacity problem
%   and reducing workers will never cure it. pctconfig does not persist
%   between sessions, which is why it is set here on every launch rather than
%   left to a preference.
%
%   Beyond that this retries: it clears stale jobs from the cluster, waits,
%   and only then steps the worker count down. A batch that runs on eight
%   workers tonight is worth more than one that does not run at all, and the
%   reduction is printed so the manifest's pool size is never a surprise. If
%   nothing works the error names the specific things to check, because the
%   default message points only at the profile manager.
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

    % Oversubscription is legal and sometimes wanted, but it is not free: the
    % runs are CPU bound, so twice the workers on the same cores is roughly
    % twice the wall time per run, and each worker holds a full simulation in
    % memory. Said once, here, rather than discovered from the wall times.
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
    % The range in force when the batch started, so the "leave as configured"
    % candidate means that and not whatever a previous failed attempt set.
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
                    % Raise the profile's ceiling if it is below the request,
                    % which is a separate failure from the port timeout and
                    % would otherwise stop a valid oversubscribed pool.
                    % Wrapped on its own: if the property is not writable on
                    % this release that must not consume the attempt.
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

%% ==========================================================================
function ranges = portCandidates(cfg)
%portCandidates Client listening ranges to try, in order.
%   [] means leave whatever is configured (the 27370-28370 default on a fresh
%   session); 0 means ephemeral, which the OS assigns from what is actually
%   free and therefore cannot land inside a fixed reservation; a two-element
%   vector is an explicit range. The defaults walk from "as shipped" to
%   ephemeral to two high fixed ranges, which covers both a reserved block
%   over 27370 and a firewall rule that only permits certain ports.
    ranges = {[], 0, [40000 41000], [21000 22000]};
    if isfield(cfg.batch, 'poolPortRanges') && ~isempty(cfg.batch.poolPortRanges)
        ranges = cfg.batch.poolPortRanges;
        if ~iscell(ranges), ranges = {ranges}; end
    end
end

function applyPortRange(r, origRange)
%applyPortRange Set the client port range for the next pool start.
%   Failure here is reported and not fatal: an unusable range must fall
%   through to the next candidate rather than end the batch.
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

%% ==========================================================================
function clearStalePool()
%clearStalePool Best-effort removal of the state a failed start leaves behind.
%   A half-opened pool and the job objects behind it keep their ports, so a
%   retry without this usually fails the same way. Everything here is
%   wrapped: a cleanup that throws would mask the error being recovered from.
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

%% ==========================================================================
function assertParallelAvailable()
%assertParallelAvailable Hard error if parfor cannot run in parallel.
%   Deliberately not a fall back to serial execution: a batch that
%   silently loses its parallelism looks like a hang rather than a
%   misconfiguration.
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

%% ==========================================================================
function M = buildManifest(cfg, runCfgs, metas, results)
%buildManifest One row per run, recording the generation parameters (D5.5).
%   simReached_s and truncated are kept although a run is now all-or-nothing:
%   they are what phase5_CostModel divides the wall time by, and they leave
%   the column set stable against the manifests already written.
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
            % Skipped or failed: name the CSV the run would have written. A
            % skipped run's own manifest, from the batch that produced it,
            % holds its row count and wall time.
            M.csvFile(i) = string(fullfile(char(rc.outputDir), ...
                sprintf('features_%s_seed%d.csv', rc.scenario, rc.seed)));
        end
    end
end

%% ==========================================================================
function writeManifest(M, outPath)
%writeManifest Plain comma-separated manifest with quoted text fields.
%   Written by hand rather than with writetable so the quoting of the
%   error column is explicit and the file has no release-dependent
%   formatting, matching the discipline used for the feature CSV.
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
%quoteField Wrap a text field in quotes when it needs it.
%   The quote character is held in a variable rather than written inline,
%   because a literal quote next to a closing parenthesis inside square
%   brackets is the one place MATLAB's transpose and string syntaxes look
%   alike to a reader.
    q = '"';
    s = strrep(s, sprintf('\n'), ' ');
    s = strrep(s, sprintf('\r'), ' ');
    if contains(s, ',') || contains(s, q)
        s = [q, strrep(s, q, [q q]), q];
    end
end
