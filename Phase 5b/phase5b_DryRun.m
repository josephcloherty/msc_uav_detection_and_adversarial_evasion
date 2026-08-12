function M = phase5b_DryRun(cfg)
%phase5b_DryRun Expand the whole batch without simulating anything.
%
%   M = phase5b_DryRun()      uses phase5b_Config()
%   M = phase5b_DryRun(CFG)
%
%   Builds every run configuration the batch would execute, runs the same
%   assertions as phase5b_RunBatch, and prints the dataset shape and projected
%   wall time. M is the manifest table with the outcome columns empty.

    if nargin < 1 || isempty(cfg)
        cfg = phase5b_Config();
    end
    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, 'core', 'functions'));

    % Must mirror the phase5b_RunBatch enumeration exactly, or the projection
    % stops describing the batch it is meant to price.
    seeds = cfg.batch.seedRange(:)';
    cycle = string(cfg.batch.scenarioCycle(:))';
    nRuns = min(numel(seeds), cfg.batch.maxRuns);
    seeds = seeds(1:nRuns);
    scenarios = phase5b_ScenarioFor(cfg, seeds);

    rows = cell(nRuns, 1);
    for i = 1:nRuns
        [rc, mt] = phase5b_ScenarioGen(cfg, seeds(i), scenarios(i));
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

    % Approximate: extraction anchors the first window on the first retained
    % scan rather than on settleTime.
    winPerUE = floor((cfg.window.simulationTime - cfg.window.settleTime - ...
        cfg.window.windowLen) / cfg.window.windowStride) + 1;
    estRows = sum(M.numUE) * winPerUE;

    fprintf('\nPhase 5b dry run: %d run(s)\n', nRuns);
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

    if isfield(cfg.batch, 'costModel')
        nW = cfg.batch.numWorkers;
        if isempty(nW), nW = feature('numcores'); end
        nW = nW(1);
        kInfo = phase5b_CostModel('effective', cfg, nW);
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
        fprintf('  batch wall time    %s (slowest run; all start together)\n', ...
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
