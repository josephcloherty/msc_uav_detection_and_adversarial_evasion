function M = phase7_DryRun(cfg)
%phase7_DryRun Expand the whole batch without simulating anything.
%
%   M = phase7_DryRun()      uses phase7_Config()
%   M = phase7_DryRun(CFG)
%
%   Builds every run configuration the batch would execute, runs the same
%   assertions as phase7_RunBatch, and prints the dataset shape and projected
%   wall time. M is the manifest table with the outcome columns empty.

    if nargin < 1 || isempty(cfg)
        cfg = phase7_Config();
    end
    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, 'core', 'functions'));

    % Must mirror the phase7_RunBatch enumeration exactly, or the projection
    % stops describing the batch it is meant to price.
    seeds = cfg.batch.seedRange(:)';
    cycle = string(cfg.batch.scenarioCycle(:))';
    conds = string(cfg.evasion.conditions(:))';
    nSeed = numel(seeds);
    nCond = numel(conds);

    runSeed = repelem(seeds, nCond);
    runCond = repmat(conds, 1, nSeed);
    runScen = cycle(mod(runSeed - 1, numel(cycle)) + 1);

    nRuns = min(numel(runSeed), cfg.batch.maxRuns);
    runSeed = runSeed(1:nRuns);
    runCond = runCond(1:nRuns);
    runScen = runScen(1:nRuns);
    seeds = runSeed; scenarios = runScen;

    % The evasion overlay is skipped: it touches only altitude, traffic and
    % speed, none of which feed numUE, numAerial or the cost model.
    rows = cell(nRuns, 1);
    for i = 1:nRuns
        [rc, mt] = phase7_ScenarioGen(cfg, runSeed(i), runScen(i));
        rows{i} = struct('runIdx', i, 'condition', runCond(i), ...
            'scenario', mt.scenario, ...
            'seed', mt.seed, 'numGNB', mt.numGNB, ...
            'siteRadius_m', mt.siteRadius_m, ...
            'ueAreaSpan_m', mt.ueAreaSpan_m, 'numUE', mt.numUE, ...
            'numTerrestrial', mt.numTerrestrial, 'numAerial', mt.numAerial, ...
            'isMultiAerial', double(mt.isMultiAerial), ...
            'aerialFraction', mt.aerialFraction, ...
            'anchorLoadMax', mt.anchorLoadMax, ...
            'minAerialAlt_m', min(mt.aerialAlt_m), ...
            'maxAerialAlt_m', max(mt.aerialAlt_m), ...
            'simTime_s', rc.simulationTime);
    end
    M = struct2table([rows{:}]);

    % Approximate: extraction anchors the first window on the first retained
    % scan rather than on settleTime.
    winPerUE = floor((cfg.window.simulationTime - cfg.window.settleTime - ...
        cfg.window.windowLen) / cfg.window.windowStride) + 1;
    estRows = sum(M.numUE) * winPerUE;

    fprintf('\nPhase 7 dry run: %d condition(s) x %d seed(s) = %d run(s)\n', ...
        nCond, nSeed, nRuns);
    fprintf('  seeds              %d to %d\n', min(seeds), max(seeds));
    for k = 1:nCond
        sel = M.condition == conds(k);
        switch conds(k)
            case "lowAltitude"
                note = sprintf('aerial pinned to %.1f m', cfg.evasion.lowAltitude_m);
            case "trafficReshaping"
                note = 'aerial traffic set to the terrestrial profile';
            case "lowAltLowSpeed"
                note = sprintf(['aerial pinned to %.1f m, terrestrial traffic ' ...
                    'and speeds'], cfg.evasion.lowAltitude_m);
            otherwise
                note = 'no overlay';
        end
        fprintf('  %-17s %d run(s), %d UE-runs, %d aerial UE-runs | %s\n', ...
            conds(k), sum(sel), sum(M.numUE(sel)), sum(M.numAerial(sel)), note);
    end
    for k = 1:numel(cycle)
        sel = M.scenario == cycle(k);
        fprintf('  %-4s               %d run(s), %d UE-runs, %d aerial UE-runs\n', ...
            cycle(k), sum(sel), sum(M.numUE(sel)), sum(M.numAerial(sel)));
    end
    fprintf('  multi-aerial runs  %d of %d (%.0f%%)\n', ...
        sum(M.isMultiAerial), nRuns, 100*mean(M.isMultiAerial));
    fprintf('  aerial fraction    %.3f mean, %.3f to %.3f\n', ...
        mean(M.aerialFraction), min(M.aerialFraction), max(M.aerialFraction));
    fprintf('  aerial altitude    %.1f to %.1f m\n', ...
        min(M.minAerialAlt_m), max(M.maxAerialAlt_m));
    fprintf('  UEs per gNB (SRS)  %d max, limit %d\n', ...
        max(M.numUE), cfg.srs.maxUEsPerGNB);
    fprintf('  windows per UE     %d (approx)\n', winPerUE);
    fprintf('  estimated rows     %d (approx)\n', estRows);

    if isfield(cfg.batch, 'costModel')
        nW = cfg.batch.numWorkers;
        if isempty(nW), nW = feature('numcores'); end
        nW = nW(1);
        kInfo = phase7_CostModel('effective', cfg, nW);
        k = kInfo.k;
        perRun = k * cfg.window.simulationTime * M.numGNB .* M.numUE;
        totalCPU = sum(perRun);
        switch kInfo.source
            case "measured"
                note = sprintf('measured, %d run(s) at %d worker(s)', ...
                    kInfo.n, nW);
            case "measured-other-poolsize"
                note = sprintf(['measured at another pool size from %d ' ...
                    'run(s); a lower bound here'], kInfo.n);
            otherwise
                note = 'configured prior, no measurements yet';
        end
        fprintf('\n  cost model         %.1f s per (sim-s x gNB x UE) (%s)\n', ...
            k, note);
        fprintf('  wall per run       %s to %s\n', ...
            fmtDuration(min(perRun)), fmtDuration(max(perRun)));
        fprintf('  total CPU time     %s\n', fmtDuration(totalCPU));
        fprintf('  on %2d worker(s)    %s or more (ignores core contention)\n', ...
            nW, fmtDuration(totalCPU / nW));
        fprintf('  cost per 1k rows   %s\n', ...
            fmtDuration(1000 * totalCPU / max(estRows, 1)));
    end
    fprintf('\n');
end
