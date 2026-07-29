function M = phase5_DryRun(cfg)
%phase5_DryRun Expand the whole batch without simulating anything.
%
%   M = phase5_DryRun()      uses phase5_Config()
%   M = phase5_DryRun(CFG)
%
%   Generates every run configuration the batch would execute, checks
%   each one against the same assertions the real runner uses (SRS
%   capacity, aerial altitude above the TR 36.777 overlay floor, run
%   length against the window), and reports the resulting dataset shape:
%   how many runs per scenario, the split of single-aerial and
%   multi-aerial runs, the aerial fraction, and the estimated row count.
%
%   Cheap enough to run before every batch. It catches a misconfigured
%   population or an impossible altitude range in a second rather than
%   after the first worker has spent minutes on a doomed run, and it
%   shows what the dataset will look like before any of it exists.
%
%   Returns the same table the batch manifest is built from, with the
%   run outcome columns left empty.

    if nargin < 1 || isempty(cfg)
        cfg = phase5_Config();
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

    % Rows per run: one per UE per window position after the settle gate.
    % Approximate: the extraction anchors the first window on the first
    % retained SCAN rather than on settleTime itself, so the true count
    % can be one lower. Reported to show the dataset order of magnitude,
    % not as a contract.
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

    %% ---- wall-time projection ------------------------------------------
    % Runs are expensive enough that committing to a batch without an
    % estimate is how a weekend disappears. The constant is calibrated in
    % phase5_Config from measured smoke runs; treat the result as an
    % order of magnitude, not a promise.
    if isfield(cfg.batch, 'costModel')
        nW = cfg.batch.numWorkers;
        if isempty(nW), nW = feature('numcores'); end
        nW = nW(1);
        % Measured cost for this pool size where it exists, the configured
        % prior otherwise. The prior was calibrated on six second smoke runs
        % and understated the first real batch by more than a factor of two,
        % so a projection that ignores the measurements is not worth making.
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
        fprintf('  on %2d worker(s)    %s or more (ignores core contention)\n', ...
            nW, fmtDuration(totalCPU / nW));
        fprintf('  cost per 1k rows   %s\n', ...
            fmtDuration(1000 * totalCPU / max(estRows, 1)));
    end
    fprintf('\n');
end
