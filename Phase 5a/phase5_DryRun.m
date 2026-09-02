function M = phase5_DryRun(cfg)
% expands the whole batch without simulating anything, running the same checks
% the runner does and projecting the dataset shape and wall time.

    if nargin < 1 || isempty(cfg)
        cfg = phase5_Config();
    end
    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, 'core', 'functions'));

    seeds = cfg.batch.seedRange(:)';
    nRuns = min(numel(seeds), cfg.batch.maxRuns);
    seeds = seeds(1:nRuns);
    % same resolver the runner uses
    scenarios = phase5_ScenarioFor(cfg, seeds);

    rows = cell(nRuns, 1);
    for i = 1:nRuns
        [rc, mt] = phase5_ScenarioGen(cfg, seeds(i), scenarios(i));
        rows{i} = struct('runIdx', i, 'scenario', mt.scenario, ...
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

    % rows per run: one per UE per window after the settle gate. approximate,
    % because the first window is anchored on the first retained scan.
    winPerUE = floor((cfg.window.simulationTime - cfg.window.settleTime - ...
        cfg.window.windowLen) / cfg.window.windowStride) + 1;
    estRows = sum(M.numUE) * winPerUE;

    fprintf('\nPhase 5 dry run: %d run(s)\n', nRuns);
    fprintf('  seeds              %d to %d\n', min(seeds), max(seeds));
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

    %% wall-time projection
    % treat the result as an order of magnitude, not a promise
    if isfield(cfg.batch, 'costModel')
        nW = cfg.batch.numWorkers;
        if isempty(nW), nW = feature('numcores'); end
        nW = nW(1);
        % measured cost for this pool size where it exists, prior otherwise
        kInfo = phase5_CostModel('effective', cfg, nW);
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
        % the runner does not queue, so the batch ends with its slowest run
        fprintf('  batch wall time    %s (slowest run; all runs start together)\n', ...
            fmtDuration(max(perRun)));
        if numel(perRun) > nW
            fprintf(['  NOTE: %d run(s) enumerated for %d worker(s). The ' ...
                'runner does not queue: the last %d seed(s) would be ' ...
                'DROPPED, not deferred.\n'], numel(perRun), nW, ...
                numel(perRun) - nW);
        elseif numel(perRun) < nW
            fprintf('  NOTE: %d run(s) on %d worker(s); %d would sit idle.\n', ...
                numel(perRun), nW, nW - numel(perRun));
        end
        fprintf('  cost per 1k rows   %s\n', ...
            fmtDuration(1000 * totalCPU / max(estRows, 1)));
    end
    fprintf('\n');
end
