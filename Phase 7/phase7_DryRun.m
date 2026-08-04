function M = phase7_DryRun(cfg)
%phase7_DryRun Expand the whole batch without simulating anything.
%
%   M = phase7_DryRun()      uses phase7_Config()
%   M = phase7_DryRun(CFG)
%
%   Builds every run configuration the batch would execute, runs the same
%   assertions the real runner uses, and reports the dataset shape and the
%   projected wall time.
%
%   Worth running before every batch, since it costs a second and catches a
%   misconfigured population before a worker starts a doomed run.
%
%   Returns the table the manifest is built from, outcome columns empty.

    if nargin < 1 || isempty(cfg)
        cfg = phase7_Config();
    end
    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, 'core', 'functions'));

    seeds = cfg.batch.seedRange(:)';
    cycle = string(cfg.batch.scenarioCycle(:))';
    nRuns = min(numel(seeds), cfg.batch.maxRuns);
    seeds = seeds(1:nRuns);
    scenarios = cycle(mod((0:nRuns-1), numel(cycle)) + 1);

    rows = cell(nRuns, 1);
    for i = 1:nRuns
        [rc, mt] = phase7_ScenarioGen(cfg, seeds(i), scenarios(i));
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

    % One row per UE per window position after the settle gate.
    % Approximate, because the extraction anchors the first window on the
    % first retained scan rather than on settleTime.
    winPerUE = floor((cfg.window.simulationTime - cfg.window.settleTime - ...
        cfg.window.windowLen) / cfg.window.windowStride) + 1;
    estRows = sum(M.numUE) * winPerUE;

    fprintf('\nPhase 7 dry run: %d run(s)\n', nRuns);
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
    % Treat this as an order of magnitude, not a promise.
    if isfield(cfg.batch, 'costModel')
        nW = cfg.batch.numWorkers;
        if isempty(nW), nW = feature('numcores'); end
        nW = nW(1);
        % Measured cost for this pool size if there is any, prior otherwise.
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
