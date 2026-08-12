function report = phase7_SmokeTest(varargin)
%phase7_SmokeTest Verify a Phase 7 install reproduces a known-good machine.
%
%   report = phase7_SmokeTest()
%   report = phase7_SmokeTest('tolerance', 1e-6, 'rebaseline', false, ...)
%
%   With no data/smoke_test/phase7_smoke_check.mat on disk, this run writes
%   one as the reference; only do that on a machine already known good. With
%   one present, the same work is repeated and compared metric by metric.
%
%   Stages:
%     A  environment  products, licences and every non-base function called
%     B  analytics    TR 36.777 pathloss, LOS probability, shadow fading,
%                     the spatially-consistent LOS field
%     C  batch        two runs through phase7_RunBatch on a 2-worker pool,
%                     covering pool startup, the progress DataQueue, the
%                     simulator, the SRS and RNTI chain, the scheduler logs,
%                     feature extraction, the CSV writer, the replay bundle
%                     and the manifest; two to five minutes



    opt = parseOpts(varargin{:});

    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, 'core', 'functions'));

    smokeDir = fullfile(here, 'data', 'smoke_test');
    artDir   = fullfile(smokeDir, 'artifacts');
    checkMat = fullfile(smokeDir, 'phase7_smoke_check.mat');
    checkTxt = fullfile(smokeDir, 'phase7_smoke_check.txt');
    if ~exist(smokeDir, 'dir'), mkdir(smokeDir); end

    haveCheck = isfile(checkMat) && ~opt.rebaseline;
    fprintf('\nPhase 7 smoke test\n');
    if haveCheck
        fprintf('  comparing against %s\n', checkMat);
    elseif opt.rebaseline && isfile(checkMat)
        fprintf('  REBASELINING: the existing check file will be replaced.\n');
    else
        fprintf(['  no check file, so this run becomes the reference.\n' ...
            '  Only keep it if this machine is already known good.\n']);
    end

    wall = tic;
    K = cell(0, 2);   % {name, value} accumulator for every compared metric

    env = checkEnvironment();
    fprintf('  A environment    %s, %s, %d core(s)\n', ...
        env.release, env.simProduct, env.cores);

    KB = analyticMetrics();
    K = [K; KB];
    fprintf('  B analytics      %d metric(s)\n', size(KB, 1));

    smokeCfg = smokeConfig(artDir);
    if opt.quick
        fprintf('  C batch          skipped ("quick")\n');
    else
        KC = batchMetrics(smokeCfg, artDir, opt.keepArtifacts);
        K = [K; KC];
        fprintf('  C batch          %d metric(s)\n', size(KC, 1));
    end

    now_ = struct();
    now_.version = 1;                     % check-file layout version
    now_.stamp   = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    now_.env     = env;
    now_.names   = string(K(:, 1));
    % double() rather than cell2mat, so a logical or integer metric does not
    % break the concatenation.
    now_.values  = cellfun(@double, K(:, 2));
    now_.schema  = phase5FeatureSchema();
    now_.quick   = opt.quick;
    % Recorded so a later run can tell that the TEST changed rather than
    % reporting the whole batch as a regression.
    now_.testCfg = struct( ...
        'seeds',     smokeCfg.batch.seedRange, ...
        'scenarios', smokeCfg.batch.scenarioCycle, ...
        'numGNB',    smokeCfg.scenarios.UMa.topology.numGNB, ...
        'numUE',     smokeCfg.population.numTerrestrialUE + ...
                     smokeCfg.population.singleAerialCount, ...
        'simTime',   smokeCfg.window.simulationTime, ...
        'windowLen', smokeCfg.window.windowLen, ...
        'stride',    smokeCfg.window.windowStride, ...
        'settle',    smokeCfg.window.settleTime);

    % No check file yet, so this run becomes the reference.
    if ~haveCheck
        check = now_; %#ok<NASGU>
        save(checkMat, 'check', '-v7');
        writeReadable(checkTxt, now_);
        fprintf(['\nCheck file written: %s\n  %d metric(s) recorded on ' ...
            '%s / %s.\n  Keep it with the repository; every later run on ' ...
            'any machine compares against it.\n'], ...
            checkMat, numel(now_.names), env.release, env.computer);
        fprintf('Smoke test finished in %.1f s.\n\n', toc(wall));
        report = table(now_.names, now_.values, ...
            'VariableNames', {'metric', 'reference'});
        return;
    end

    S = load(checkMat, 'check');
    ref = S.check;
    assertComparable(ref, now_);

    report = compareMetrics(ref, now_, opt.tolerance);
    printReport(report, opt.tolerance);

    nFail = sum(~report.pass);
    fprintf('\nFinished in %.1f s: %d of %d metric(s) matched.\n', ...
        toc(wall), height(report) - nFail, height(report));
    if nFail > 0 && opt.errorOnFail
        error('phase7_SmokeTest:mismatch', ...
            ['%d metric(s) differ from the check file recorded on %s / ' ...
             '%s. This install does not reproduce the reference machine; ' ...
             'the table above names which stage broke.'], ...
            nFail, ref.env.release, ref.env.computer);
    elseif nFail == 0
        fprintf('PASS: the simulator reproduces the reference machine.\n\n');
    end
end

function env = checkEnvironment()
%checkEnvironment Products, licences and every non-base function we call.
%   Errors rather than reports, because none of this is worth a batch.

    env = struct();
    env.release  = string(version('-release'));
    env.computer = string(computer('arch'));
    env.host     = string(getenvOr('COMPUTERNAME', getenvOr('HOSTNAME', '?')));
    env.cores    = feature('numcores');

    v = ver;
    installed = string({v.Name});

    % 5G Toolbox and Parallel Computing Toolbox are unconditional.
    for p = ["5G Toolbox", "Parallel Computing Toolbox"]
        assert(any(installed == p), 'phase7_SmokeTest:missingProduct', ...
            '%s is not installed. See DEPENDENCIES.md section 1.', p);
    end
    assert(license('test', 'Distrib_Computing_Toolbox') == 1, ...
        'phase7_SmokeTest:noParallelLicence', ...
        'No Parallel Computing Toolbox licence, so phase7_RunBatch cannot run.');

    % The system-level simulator moved product in R2026a, so accept either
    % route rather than pinning one; see DEPENDENCIES.md section 4.
    if any(installed == "Wireless Network Toolbox")
        env.simProduct = "Wireless Network Toolbox";
    elseif any(installed == "Communications Toolbox")
        env.simProduct = "Comms Toolbox + Wireless Network Simulation Library";
    else
        error('phase7_SmokeTest:noSimProduct', ...
            ['Neither Wireless Network Toolbox (R2026a+) nor ' ...
             'Communications Toolbox (with the Wireless Network ' ...
             'Simulation Library add-on) is installed, so there is no ' ...
             'system-level simulator to test.']);
    end

    % ver() does not list the add-on, and a missing add-on presents as a
    % missing class rather than a missing product, so resolve the entry
    % points directly.
    toolboxFcns = {'nrGNB', 'nrUE', 'nrScheduler', 'nrSRSConfig', ...
        'nrCDLChannel', 'nrPathLoss', 'nrPathLossConfig', 'nrOFDMInfo', ...
        'nrRLCBearerConfig', 'wirelessNetworkSimulator', ...
        'networkTrafficOnOff', 'db2mag', 'parpool', 'gcp'};
    missing = toolboxFcns(cellfun(@(f) exist(f) == 0, toolboxFcns)); %#ok<EXIST>
    assert(isempty(missing), 'phase7_SmokeTest:missingFunction', ...
        ['Not on the path: %s. If it is only the nr* classes the 5G ' ...
         'Toolbox is not installed; if it is wirelessNetworkSimulator or ' ...
         'networkTrafficOnOff the Wireless Network Simulation Library ' ...
         'add-on is missing.'], strjoin(missing, ', '));

    % Custom nrScheduler plug-ins arrived in R2024b and cqiLoggingScheduler
    % is built on them, so an older release fails in a way worth naming.
    tok = regexp(char(env.release), '(\d{4})([ab])', 'tokens', 'once');
    assert(~isempty(tok), 'phase7_SmokeTest:unreadableRelease', ...
        'Could not parse the MATLAB release "%s".', env.release);
    yr = str2double(tok{1});
    assert(yr > 2024 || (yr == 2024 && strcmp(tok{2}, 'b')), ...
        'phase7_SmokeTest:releaseTooOld', ...
        ['MATLAB R%s is below the R2024b floor: custom nrScheduler ' ...
         'plug-ins are what cqiLoggingScheduler is built on.'], env.release);

    % Project functions, so a partial checkout is caught before the batch.
    projFcns = {'phase7_Config', 'phase7_ScenarioGen', 'phase7_Pipeline', ...
        'phase7_RunBatch', 'phase7_ResolveRNTI', 'phase7_CostModel', ...
        'phase7_Progress', 'cqiLoggingScheduler', 'handoverManager', ...
        'trafficSampler', 'positionRecorder', 'rntiVerifier', ...
        'createScenarioChannels', 'buildAerialCDL', 'buildUMiAVChannel', ...
        'tr36777ChannelModel', 'tr36777AerialPathloss', ...
        'tr36777LOSProbability', 'tr36777ShadowFadingStd', 'linkState', ...
        'buildSpatialField', 'sampleSpatialField', 'extractWindowedFeatures', ...
        'phase5FeatureSchema', 'writeFeatureCSV', 'saveReplayFile', ...
        'losDiagnostics', 'configureULforSRS', 'hArrayGeometry', ...
        'fmtDuration'};
    missing = projFcns(cellfun(@(f) isempty(which(f)), projFcns));
    assert(isempty(missing), 'phase7_SmokeTest:incompleteCheckout', ...
        'Missing from core/functions: %s.', strjoin(missing, ', '));
end

function K = analyticMetrics()
%analyticMetrics Closed-form models and the RNG, in well under a second.
%   These are the parts a release change or a different platform can move
%   silently; if they drift, every feature row this machine writes is
%   already incomparable with the dataset.

    K = cell(0, 2);
    fc = 2.6;   % GHz, cfg.radio.carrierFrequency

    % LOS probability: one terrestrial and two aerial points per scenario,
    % so both sides of the height test are covered.
    for sc = ["UMa", "RMa", "UMi"]
        K = [K; {"B.pLOS." + sc + ".terr_h1.5_d300",  tr36777LOSProbability(sc, 1.5, 300)}]; %#ok<AGROW>
        K = [K; {"B.pLOS." + sc + ".aer_h80_d600",    tr36777LOSProbability(sc, 80, 600)}]; %#ok<AGROW>
        K = [K; {"B.pLOS." + sc + ".aer_h150_d1200",  tr36777LOSProbability(sc, 150, 1200)}]; %#ok<AGROW>
    end

    % Aerial pathloss, LOS and NLOS, at two heights.
    for sc = ["UMa", "RMa", "UMi"]
        K = [K; {"B.PL." + sc + ".los_h80_d600",   tr36777AerialPathloss(sc, true,  fc, 80,  600)}]; %#ok<AGROW>
        K = [K; {"B.PL." + sc + ".nlos_h80_d600",  tr36777AerialPathloss(sc, false, fc, 80,  600)}]; %#ok<AGROW>
        K = [K; {"B.PL." + sc + ".los_h150_d1500", tr36777AerialPathloss(sc, true,  fc, 150, 1500)}]; %#ok<AGROW>
    end

    % Shadow fading, either side of the aerial floor.
    for sc = ["UMa", "RMa", "UMi"]
        zb = 22.5; if sc == "RMa", zb = 10; end
        K = [K; {"B.SF." + sc + ".los_h80",  tr36777ShadowFadingStd(sc, true,  80,  zb)}]; %#ok<AGROW>
        K = [K; {"B.SF." + sc + ".nlos_h80", tr36777ShadowFadingStd(sc, false, 80,  zb)}]; %#ok<AGROW>
        K = [K; {"B.SF." + sc + ".los_h1.5", tr36777ShadowFadingStd(sc, true,  1.5, zb)}]; %#ok<AGROW>
    end

    % Sampling is order independent by construction, so these are exact.
    F = buildSpatialField(7, 1, 2, [-500 500 -500 500], 50);
    K = [K; {"B.field.gridNodes", F.nx * F.ny * F.n}];
    track = -400:40:400;
    u = zeros(size(track)); z = zeros(size(track));
    for k = 1:numel(track)
        [u(k), z(k)] = sampleSpatialField(F, 1, track(k), 120);
    end
    K = [K; {"B.field.u_sum",    sum(u)}];
    K = [K; {"B.field.z_sum",    sum(z)}];
    K = [K; {"B.field.z_absmax", max(abs(z))}];
    % A frozen field samples to one value along the track, which is the
    % failure mode that quietly kills dynamic LOS.
    K = [K; {"B.field.z_range",  max(z) - min(z)}];

    % Cheapest proof that a seed still means the same run on this machine.
    base = phase7_Config();
    for sc = ["UMa", "RMa", "UMi"]
        [rc, mt] = phase7_ScenarioGen(base, 13, sc);
        K = [K; {"B.gen." + sc + ".numUE",         mt.numUE}]; %#ok<AGROW>
        K = [K; {"B.gen." + sc + ".numAerial",     mt.numAerial}]; %#ok<AGROW>
        K = [K; {"B.gen." + sc + ".anchorLoadMax", mt.anchorLoadMax}]; %#ok<AGROW>
        K = [K; {"B.gen." + sc + ".uePos_sum",     sum(rc.uePositions(:))}]; %#ok<AGROW>
        K = [K; {"B.gen." + sc + ".gnbPos_sum",    sum(rc.gNBPositions(:))}]; %#ok<AGROW>
        K = [K; {"B.gen." + sc + ".ulRate_sum", ...
            sum(arrayfun(@(t) t.ul.dataRate_kbps, rc.trafficPerUE))}]; %#ok<AGROW>
        K = [K; {"B.gen." + sc + ".dlRate_sum", ...
            sum(arrayfun(@(t) t.dl.dataRate_kbps, rc.trafficPerUE))}]; %#ok<AGROW>
    end
end

function cfg = smokeConfig(artDir)
%smokeConfig The smallest batch that still exercises the whole pipeline.
%   Anything not named here stays at the phase7_Config value, so the smoke
%   test tracks the real radio, handover and channel settings rather than a
%   private copy that can drift away from them.

    cfg = phase7_Config();

    % Two runs, one per aerial channel branch: UMa-AV is CDL-D based, UMi-AV
    % goes through buildUMiAVChannel. Seeds well outside any dataset range.
    cfg.batch.seedRange       = [9001 9002];
    cfg.batch.scenarioCycle   = ["UMa", "UMi"];
    cfg.batch.maxRuns         = 2;

    % Inheriting the dataset conditions would make maxRuns 2 select two
    % branches of one seed, and the descent branches bypass the CDL-D and
    % buildUMiAVChannel paths this stage exists to exercise.
    cfg.evasion.conditions    = "honest";
    cfg.batch.numWorkers      = 2;
    cfg.batch.dataDir         = string(artDir);
    cfg.batch.tag             = "smoke";
    cfg.batch.skipExisting    = false;   % a smoke test must actually run
    cfg.batch.continueOnError = true;    % a failure belongs in the report
    cfg.batch.verboseWorkers  = false;
    cfg.batch.poolRetries     = 1;
    cfg.batch.poolRetryWait_s = 5;

    % Keep the progress DataQueue live, but quiet.
    cfg.progress.enable        = true;
    cfg.progress.updatesPerRun = 4;
    cfg.progress.minPrint_s    = 30;

    % Two UEs, one of each class: the minimum that gives both a terrestrial
    % and an aerial channel, both traffic profiles and both labels.
    cfg.population.numTerrestrialUE  = 1;
    cfg.population.pMultiAerial      = 0;
    cfg.population.singleAerialCount = 1;

    % Two cells, because one has no handover chain to measure.
    for sc = ["UMa", "RMa", "UMi"]
        cfg.scenarios.(sc).topology.numGNB = 2;
        % Shrink the UE region to the site radius so both UEs land inside
        % coverage; wall time is driven by simulated seconds, not area.
        cfg.scenarios.(sc).topology.ueAreaSpan_m = ...
            cfg.scenarios.(sc).topology.siteRadius_m;
    end

    % Shortest set that still produces rows: phase7_ScenarioGen requires
    % simulationTime > settleTime + windowLen, and this gives two windows
    % per UE so the stride is exercised rather than assumed.
    cfg.window.simulationTime = 2.0;
    cfg.window.windowLen      = 1.0;
    cfg.window.windowStride   = 0.5;
    cfg.window.settleTime     = 0.2;

    % Never auto-correct here: a mismatch should fail loudly.
    cfg.measurement.verifyRNTI      = true;
    cfg.measurement.autoCorrectRNTI = false;
    cfg.measurement.printRNTIMap    = false;

    % Kept on because writing one proves the -v7.3 path.
    cfg.replay.save         = true;
    cfg.replay.includeNodes = false;
end

function K = batchMetrics(cfg, artDir, keep)
%batchMetrics Run the tiny batch and reduce it to comparable numbers.

    K = cell(0, 2);

    % Start empty, so nothing is skipped and no stale CSV is read back as
    % this run's output.
    if exist(artDir, 'dir'), rmdir(artDir, 's'); end
    mkdir(artDir);

    fprintf(['  C batch          2 runs, 2 simulated s, 2 gNB, 2 UE, ' ...
        '2 workers; a few minutes\n\n']);
    M = phase7_RunBatch(cfg);
    fprintf('\n');

    K = [K; {"C.batch.numRuns",   height(M)}];
    K = [K; {"C.batch.numOK",     sum(M.status == "ok")}];
    K = [K; {"C.batch.numFailed", sum(M.status == "failed")}];

    % Say why now rather than reporting a hundred missing metrics.
    bad = find(M.status ~= "ok")';
    if ~isempty(bad)
        msgs = arrayfun(@(k) sprintf('%s seed %d: %s', M.scenario(k), ...
            M.seed(k), M.errorMessage(k)), bad, 'UniformOutput', false);
        error('phase7_SmokeTest:runFailed', ...
            'The smoke batch did not complete:\n  %s', strjoin(msgs, '\n  '));
    end

    for i = 1:height(M)
        p = "C.run." + M.scenario(i) + "_seed" + string(M.seed(i));

        % Deterministic columns only; wallTime_s is meant to differ.
        K = [K; {p + ".numUE",         M.numUE(i)}]; %#ok<AGROW>
        K = [K; {p + ".numAerial",     M.numAerial(i)}]; %#ok<AGROW>
        K = [K; {p + ".numGNB",        M.numGNB(i)}]; %#ok<AGROW>
        K = [K; {p + ".numRows",       M.numRows(i)}]; %#ok<AGROW>
        K = [K; {p + ".hoCountTotal",  M.hoCountTotal(i)}]; %#ok<AGROW>
        K = [K; {p + ".hoCountAerial", M.hoCountAerial(i)}]; %#ok<AGROW>
        K = [K; {p + ".pingPongTotal", M.pingPongTotal(i)}]; %#ok<AGROW>
        K = [K; {p + ".simReached_s",  M.simReached_s(i)}]; %#ok<AGROW>
        K = [K; {p + ".truncated",     M.truncated(i)}]; %#ok<AGROW>

        % A loadable variable list proves the -v7.3 writer works; file size
        % is machine dependent.
        rp = char(M.replayFile(i));
        assert(isfile(rp), 'phase7_SmokeTest:noReplay', ...
            'Replay bundle missing for %s seed %d.', M.scenario(i), M.seed(i));
        K = [K; {p + ".replayVars", numel(whos('-file', rp))}]; %#ok<AGROW>

        % Per-column, so a failure names the column that broke and an
        % all-NaN block reads as a regression rather than a rounding error.
        [colNames, nFinite, colSum] = csvColumnStats(char(M.csvFile(i)));
        for c = 1:numel(colNames)
            K = [K; {p + ".col." + colNames(c) + ".nFinite", nFinite(c)}]; %#ok<AGROW>
            K = [K; {p + ".col." + colNames(c) + ".sum",     colSum(c)}]; %#ok<AGROW>
        end
    end

    if keep
        fprintf('  artifacts kept in %s\n', artDir);
    else
        % Leftover artifacts are untidy, not a failure.
        [ok, msg] = rmdir(artDir, 's');
        if ~ok
            warning('phase7_SmokeTest:cleanupFailed', ...
                'Could not remove %s (%s); delete it by hand.', artDir, msg);
        end
    end
end

function [colNames, nFinite, colSum] = csvColumnStats(csvPath)
%csvColumnStats Per-column finite count and sum for one feature CSV.
%   The schema is asserted rather than discovered, because a drifted column
%   set is itself the failure.

    assert(isfile(csvPath), 'phase7_SmokeTest:noCSV', ...
        'Feature CSV missing: %s', csvPath);
    schema = phase5FeatureSchema();

    T = readtable(csvPath, 'TextType', 'string', ...
        'VariableNamingRule', 'preserve');
    assert(isequal(T.Properties.VariableNames, schema), ...
        'phase7_SmokeTest:schemaMismatch', ...
        ['The CSV this machine wrote does not carry the locked Phase 5 ' ...
         'column set, so its rows are not comparable with the dataset.']);
    assert(height(T) > 0, 'phase7_SmokeTest:noRows', ...
        'The run produced no feature rows.');

    % Column 1 is the scenario string; the rest are numeric.
    colNames = string(schema(2:end));
    nFinite  = zeros(numel(colNames), 1);
    colSum   = zeros(numel(colNames), 1);
    for c = 1:numel(colNames)
        v = T{:, c+1};
        f = isfinite(v);
        nFinite(c) = sum(f);
        % NaN, not 0, when the column is entirely NaN, so the comparison
        % can insist it is still NaN.
        if any(f), colSum(c) = sum(v(f)); else, colSum(c) = NaN; end
    end
end

function report = compareMetrics(ref, now_, tol)
%compareMetrics Metric by metric verdict, tolerant on value, strict on NaN.

    % A quick run produces no Stage C metrics, so drop the reference's
    % rather than report every one as missing.
    if now_.quick
        keepRef = ~startsWith(ref.names, "C.");
        ref.names  = ref.names(keepRef);
        ref.values = ref.values(keepRef);
    end

    allNames = unique([ref.names; now_.names], 'stable');
    n = numel(allNames);
    refVal  = nan(n, 1);
    nowVal  = nan(n, 1);
    relDiff = nan(n, 1);
    pass    = false(n, 1);
    note    = strings(n, 1);

    for i = 1:n
        ir = find(ref.names  == allNames(i), 1);
        in = find(now_.names == allNames(i), 1);
        if isempty(ir)
            nowVal(i) = now_.values(in);
            note(i) = "absent from the check file";
            continue;
        elseif isempty(in)
            refVal(i) = ref.values(ir);
            note(i) = "not produced on this machine";
            continue;
        end
        a = ref.values(ir); b = now_.values(in);
        refVal(i) = a; nowVal(i) = b;
        if isnan(a) && isnan(b)
            % In a two-second run plenty of columns are legitimately NaN.
            pass(i) = true; note(i) = "NaN both sides";
        elseif isnan(a) || isnan(b)
            note(i) = "NaN on one side only";
        else
            % Floored at 1 so a metric near zero is not judged against its
            % own noise.
            relDiff(i) = abs(a - b) / max(1, abs(a));
            pass(i) = relDiff(i) <= tol;
            if ~pass(i), note(i) = "outside tolerance"; end
        end
    end

    report = table(allNames, refVal, nowVal, relDiff, pass, note, ...
        'VariableNames', {'metric', 'reference', 'thisMachine', ...
                          'relDiff', 'pass', 'note'});
end

function printReport(report, tol)
%printReport A count per stage, then every failure in full.

    stage = extractBefore(report.metric, 2);
    fprintf('\n  %-16s %8s %8s\n', 'stage', 'passed', 'failed');
    for s = unique(stage, 'stable')'
        sel = stage == s;
        fprintf('  %-16s %8d %8d\n', stageName(s), ...
            sum(report.pass(sel)), sum(~report.pass(sel)));
    end

    bad = report(~report.pass, :);
    if isempty(bad), return; end
    fprintf('\nMismatched metrics (relative tolerance %.1e):\n', tol);
    fprintf('  %-54s %13s %13s %9s  %s\n', ...
        'metric', 'reference', 'this machine', 'relDiff', 'note');
    for i = 1:height(bad)
        fprintf('  %-54s %13.6g %13.6g %9.2e  %s\n', ...
            bad.metric(i), bad.reference(i), bad.thisMachine(i), ...
            bad.relDiff(i), bad.note(i));
    end
end

function n = stageName(s)
%stageName Readable label from the metric-name prefix.
    switch string(s)
        case "A", n = 'A environment';
        case "B", n = 'B analytics';
        case "C", n = 'C batch';
        otherwise, n = char(s);
    end
end

function assertComparable(ref, now_)
%assertComparable Refuse to compare a check file that was made differently.
%   Otherwise a change to this test reads as a broken simulator.

    assert(isfield(ref, 'version') && isequal(ref.version, now_.version), ...
        'phase7_SmokeTest:staleCheckFile', ...
        ['The check file uses layout version %d and this test writes %d. ' ...
         'Re-record it on a known-good machine with ' ...
         'phase7_SmokeTest(''rebaseline'', true).'], ...
        getfieldOr(ref, 'version', 0), now_.version);

    assert(isequal(ref.schema, now_.schema), ...
        'phase7_SmokeTest:schemaChanged', ...
        ['The feature schema has changed since the check file was ' ...
         'recorded, so no column comparison is meaningful. Re-record it.']);

    assert(isequal(ref.testCfg, now_.testCfg), ...
        'phase7_SmokeTest:testConfigChanged', ...
        ['The smoke configuration differs from the one the check file was ' ...
         'recorded with, so the batch metrics are not comparable. ' ...
         'Re-record it on a known-good machine.']);

    if ref.quick && ~now_.quick
        warning('phase7_SmokeTest:quickBaseline', ...
            ['The check file was recorded with ''quick'', so it holds no ' ...
             'batch metrics and Stage C goes unchecked.']);
    end
end

function writeReadable(txtPath, rec)
%writeReadable A plain-text twin of the check file, for diffing by eye.
    fid = fopen(txtPath, 'w');
    if fid < 0, return; end
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid, 'Phase 7 smoke-test reference\n');
    fprintf(fid, 'recorded   %s\n', rec.stamp);
    fprintf(fid, 'release    R%s\n', rec.env.release);
    fprintf(fid, 'arch       %s\n', rec.env.computer);
    fprintf(fid, 'host       %s\n', rec.env.host);
    fprintf(fid, 'simulator  %s\n', rec.env.simProduct);
    fprintf(fid, 'cores      %d\n', rec.env.cores);
    fprintf(fid, 'quick      %d\n', rec.quick);
    fprintf(fid, '\n%-56s %s\n', 'metric', 'value');
    for i = 1:numel(rec.names)
        fprintf(fid, '%-56s %.10g\n', rec.names(i), rec.values(i));
    end
end

function opt = parseOpts(varargin)
%parseOpts Name-value options with defaults.
    opt = struct('tolerance', 1e-6, 'rebaseline', false, 'quick', false, ...
        'keepArtifacts', false, 'errorOnFail', true);
    assert(mod(numel(varargin), 2) == 0, 'phase7_SmokeTest:badOptions', ...
        'Options must be name-value pairs.');
    valid = fieldnames(opt);
    for k = 1:2:numel(varargin)
        f = validatestring(varargin{k}, valid);
        opt.(f) = varargin{k+1};
    end
end

function v = getfieldOr(s, f, dflt)
%getfieldOr Field value with a default, so an older check file still loads.
    if isstruct(s) && isfield(s, f), v = s.(f); else, v = dflt; end
end

function v = getenvOr(name, dflt)
%getenvOr Environment variable with a default.
    v = getenv(name);
    if isempty(v), v = dflt; end
end
