function ok = phase5_SmokeCheck(cfg, scenarios)
% runs one short simulation per scenario through the real pipeline and checks
% the resulting CSV, so a broken fork is caught before a long batch.

    if nargin < 1 || isempty(cfg)
        cfg = phase5_Config();
    end
    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, 'core', 'functions'));

    if nargin < 2 || isempty(scenarios)
        scenarios = unique(string(cfg.batch.scenarioCycle), 'stable');
    end
    scenarios = string(scenarios);

    %% smoke overrides: short run, small population, separate folder
    smokeDir = fullfile(here, 'data', 'smoke');
    if ~exist(smokeDir, 'dir'), mkdir(smokeDir); end
    cfg.batch.dataDir            = string(smokeDir);
    cfg.batch.verboseWorkers     = true;      % diagnostic run
    cfg.window.simulationTime    = 6;
    cfg.window.windowLen         = 3;
    cfg.window.windowStride      = 1;
    cfg.window.settleTime        = 0.5;
    cfg.population.numTerrestrialUE   = 2;
    cfg.population.pMultiAerial       = 0;    % one aerial UE
    cfg.population.singleAerialCount  = 1;
    cfg.replay.save              = false;
    cfg.progress.enable          = false;

    seed = 999;   % reserved for smoke

    schema = phase5FeatureSchema();
    names  = ["completes", "schema", "rows", "bothClasses", "servSINR", ...
              "neighbours", "cqi", "traffic", "forkChannel", ...
              "losDynamic", "rank", "geometry"];
    results = strings(numel(scenarios), numel(names));
    ok = true;

    fprintf('\nPhase 5 smoke check: %d scenario(s), %.1f s each, seed %d\n', ...
        numel(scenarios), cfg.window.simulationTime, seed);
    fprintf('Output (not dataset): %s\n\n', smokeDir);

    for k = 1:numel(scenarios)
        sc = scenarios(k);
        res = repmat("-", 1, numel(names));
        try
            rc = phase5_ScenarioGen(cfg, seed, sc);
            summary = phase5_Pipeline(rc);
            res(1) = "pass";

            T = readtable(summary.csvPath, 'TextType', 'string');
            res(2) = passIf(isequal(T.Properties.VariableNames, schema));
            res(3) = passIf(height(T) > 0);
            if height(T) > 0
                res(4) = passIf(any(T.label == 0) && any(T.label == 1));
                res(5) = passIf(any(isfinite(T.servSINR_mean_dB)));
                res(6) = passIf(any(T.numAboveThr_mean > 1));
                res(7) = passIf(~all(isnan(T.cqi_mean)));
                res(8) = passIf(any(T.ulVol_bytes > 0));
            end
            if isempty(rc.aerialChannelBuilder)
                res(9) = "n/a";
            else
                res(9) = passIf(isa(rc.aerialChannelBuilder, 'function_handle'));
            end

            % Phase 5 checks. transitions are not asserted: a 3 s run is
            % too short for a UE to cross a correlation cell.
            res(10) = passIf(summary.losDynamic);

            if height(T) > 0
                % rank indicator and subband spread must reach the CSV
                res(11) = passIf(~all(isnan(T.ri_mean)) ...
                    || ~all(isnan(T.cqiSubbandSpread_mean)));
                % the per-cell SINR snapshot must be readable
                res(12) = passIf(~all(isnan(T.nbrWithin3dB_mean)));
            end
        catch err
            res(1) = "FAIL";
            fprintf(2, '%s raised: %s\n', sc, err.message);
            if ~isempty(err.stack)
                fprintf(2, '   at %s line %d\n', err.stack(1).name, ...
                    err.stack(1).line);
            end
        end
        results(k, :) = res;
        ok = ok && ~any(results(k, :) == "FAIL");
    end

    %% report
    fprintf('\n%-6s', 'scen');
    fprintf('%-13s', names{:});
    fprintf('\n');
    for k = 1:numel(scenarios)
        fprintf('%-6s', scenarios(k));
        fprintf('%-13s', results(k, :));
        fprintf('\n');
    end
    if ok
        fprintf('\nAll scenarios passed. Safe to run phase5_RunBatch.\n\n');
    else
        fprintf(2, ['\nOne or more scenarios failed. Fix before running ' ...
            'the batch, or remove the failing scenario from ' ...
            'cfg.batch.scenarioCycle.\n\n']);
    end
end

function s = passIf(tf)
    if tf, s = "pass"; else, s = "FAIL"; end
end
