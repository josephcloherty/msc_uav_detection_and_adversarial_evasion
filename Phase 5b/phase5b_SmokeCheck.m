function ok = phase5b_SmokeCheck(cfg, scenarios)
%phase5b_SmokeCheck Short end-to-end run of each scenario before a batch.
%
%   ok = phase5b_SmokeCheck()                 checks the configured cycle
%   ok = phase5b_SmokeCheck(CFG)              checks a modified configuration
%   ok = phase5b_SmokeCheck(CFG, ["UMi"])     checks named scenarios only
%
%   Runs one short simulation per scenario through the real pipeline, then
%   checks the resulting CSV against what a usable dataset row has to
%   contain. Returns true only if every scenario passes.
%
%   A scenario can be configured correctly and still produce no usable rows,
%   and a three minute check ahead of a batch of tens of runs is a better
%   trade than a column of NaNs afterwards.
%
%   The check overrides the run to be short and small, disables replay, and
%   writes to <Phase 7 copy>/data/smoke, so nothing it produces can reach the
%   dataset. Its window length differs from the dataset setting, so its rows
%   are deliberately NOT comparable with dataset rows.
%
%   Runs serially: no pool is needed and a failure is easier to read.
%
%   CHECKS PER SCENARIO
%     1  pipeline completes without error
%     2  CSV written, header is exactly the locked schema
%     3  at least one feature row produced
%     4  both classes present (label 0 and label 1)
%     5  serving SINR finite on some rows
%     6  more than one gNB visible on some rows (neighbour measurement alive)
%     7  CQI column not entirely NaN (custom scheduler logging alive)
%     8  uplink traffic volume positive somewhere (sources alive)
%     9  aerial rows carry the fork channel builder where one is configured
%    10  RSRP, RSSI and RSRQ not entirely NaN (the power tap is alive)

    if nargin < 1 || isempty(cfg)
        cfg = phase5b_Config();
    end
    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, 'core', 'functions'));

    if nargin < 2 || isempty(scenarios)
        scenarios = unique(string(cfg.batch.scenarioCycle), 'stable');
    end
    scenarios = string(scenarios);

    %% ---- smoke overrides -------------------------------------------------
    % Short run, small population, no replay, separate output folder.
    smokeDir = fullfile(here, 'data', 'smoke');
    if ~exist(smokeDir, 'dir'), mkdir(smokeDir); end
    cfg.batch.dataDir            = string(smokeDir);
    cfg.batch.verboseWorkers     = true;      % this is a diagnostic run
    cfg.window.simulationTime    = 2;
    cfg.window.windowLen         = 1;
    cfg.window.windowStride      = 0.5;
    cfg.window.settleTime        = 0.5;
    cfg.population.numTerrestrialUE   = 2;
    cfg.population.pMultiAerial       = 0;    % one aerial UE, deterministic
    cfg.population.singleAerialCount  = 1;
    cfg.replay.save              = false;
    cfg.progress.enable          = false;

    seed = 999;   % reserved for smoke runs, outside any dataset seed range

    schema = phase5bFeatureSchema();
    names  = ["completes", "schema", "rows", "bothClasses", "servSINR", ...
              "neighbours", "cqi", "traffic", "forkChannel", ...
              "losDynamic", "rank", "geometry", "power", "powerSane"];
    results = strings(numel(scenarios), numel(names));
    ok = true;

    fprintf('\nPhase 5b smoke check: %d scenario(s), %.1f s each, seed %d\n', ...
        numel(scenarios), cfg.window.simulationTime, seed);
    fprintf('Output (not dataset): %s\n\n', smokeDir);

    for k = 1:numel(scenarios)
        sc = scenarios(k);
        res = repmat("-", 1, numel(names));
        try
            rc = phase5b_ScenarioGen(cfg, seed, sc);
            summary = phase5b_Pipeline(rc);
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

            % --- Phase 5 checks -------------------------------------------
            % losDynamic: the state must be coming from the spatially
            % consistent field, not the frozen setup-time draw. Transitions
            % are NOT asserted: a 3 s smoke run is far too short for a UE to
            % cross a 50 m correlation cell, and demanding a transition here
            % would make the check fail for a correct simulator.
            res(10) = passIf(summary.losDynamic);

            if height(T) > 0
                % rank: the rank indicator and subband spread must be
                % reaching the CSV. All-NaN means the UEContext probe found
                % nothing and every rank feature is dead weight; run
                % phase4SchedulerCheck to see the actual layout.
                res(11) = passIf(~all(isnan(T.ri_mean)) ...
                    || ~all(isnan(T.cqiSubbandSpread_mean)));
                % geometry: the per-cell SINR snapshot must be readable, or
                % the whole cell-crowding block is NaN.
                res(12) = passIf(~all(isnan(T.nbrWithin3dB_mean)));
                % power: the tap must be reaching the CSV. All-NaN means no
                % absolute level was recorded on the uplink packet path and
                % the whole Phase 5b block is dead weight. RSRQ is checked
                % too, since it needs both of the other two to exist.
                res(13) = passIf(~all(isnan(T.rsrp_mean_dBm)) ...
                    && ~all(isnan(T.rssi_mean_dBm)) ...
                    && ~all(isnan(T.rsrq_mean_dB)));
                % powerSane: the three must satisfy the identities they are
                % defined by, not merely be non-NaN. A tap reading the wrong
                % packet, a receive gain applied twice or a resource block
                % count off by a factor still produces finite numbers, and
                % nothing downstream would notice.
                %
                % Every bound here is exact rather than a plausible-looking
                % constant:
                %   RSRQ = 10log10(N) + RSRP - RSSI, and RSSI >= the signal
                %   alone, so RSRQ <= -10log10(12) = -10.79 dB with equality
                %   only at infinite SINR. Above that is arithmetically
                %   impossible.
                %   RSSI - RSRP >= 10log10(12N) by the same construction,
                %   which is about 27.9 dB at 51 resource blocks.
                %   RSRP is a received power at the gNB after pathloss, so it
                %   is far below 0 dBm; a positive value means the tap read
                %   something that is not a received power.
                res(14) = passIf(powerSane(T));
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

    %% ---- report ------------------------------------------------------------
    fprintf('\n%-6s', 'scen');
    fprintf('%-13s', names{:});
    fprintf('\n');
    for k = 1:numel(scenarios)
        fprintf('%-6s', scenarios(k));
        fprintf('%-13s', results(k, :));
        fprintf('\n');
    end
    if ok
        fprintf('\nAll scenarios passed. Safe to run phase5b_RunBatch.\n\n');
    else
        fprintf(2, ['\nOne or more scenarios failed. Fix before running ' ...
            'the batch, or remove the failing scenario from ' ...
            'cfg.batch.scenarioCycle.\n\n']);
    end
end

%% ----------------------------------------------------------------------
function s = passIf(tf)
    if tf, s = "pass"; else, s = "FAIL"; end
end

%% ----------------------------------------------------------------------
function tf = powerSane(T)
%powerSane The three power columns against the identities that define them.
%   Every bound is exact, so a failure here is a real defect rather than an
%   unlucky short run. Windows with no observation are NaN and are skipped;
%   the liveness check already refuses an all-NaN block.
    rsrpHi = T.rsrp_max_dBm;
    rsrqHi = T.rsrq_max_dB;
    rsrpMu = T.rsrp_mean_dBm;
    rssiMu = T.rssi_mean_dBm;

    tf = true;

    % RSRQ = 10log10(N) + RSRP - RSSI with RSSI >= signal alone, so the
    % interference-free limit -10log10(12) is a hard ceiling.
    v = rsrqHi(~isnan(rsrqHi));
    tf = tf && ~isempty(v) && all(v <= -10*log10(12) + 1e-6);

    % RSSI exceeds RSRP by at least 10log10(12*numRB), about 27.9 dB at the
    % 51 resource blocks of 20 MHz at 30 kHz SCS. 20 dB is the loose form of
    % that, which holds for any bandwidth this project would use.
    ok = ~isnan(rsrpMu) & ~isnan(rssiMu);
    tf = tf && any(ok) && all(rssiMu(ok) - rsrpMu(ok) >= 20);

    % A received power at the gNB after pathloss. Positive would mean the tap
    % read a transmit power, or a gain applied where a loss belonged.
    v = rsrpHi(~isnan(rsrpHi));
    tf = tf && all(v < 0);
end
