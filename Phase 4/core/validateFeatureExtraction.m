function validateFeatureExtraction()
%validateFeatureExtraction Unit test of the D4.2 extraction and CSV writer.
%
%   Runs in seconds, no simulation needed. Drives the REAL
%   extractWindowedFeatures and writeFeatureCSV with synthetic logs whose
%   windowed features are known in closed form, then checks:
%     1. The output column set equals the locked Phase 4 schema, and the
%        Phase 3 schema is an exact prefix of it (the append-only
%        contract).
%     2. Labels are carried through correctly.
%     3. CQI block: a linear CQI ramp of known slope gives the expected
%        mean and trend; a constant CQI gives zero variance and slope.
%     4. MCS block: known DL/UL grant streams give the expected moments.
%     5. Traffic block: constant-rate cumulative counters give the
%        expected per-window volumes, throughput, asymmetry sign, and
%        near-zero burstiness; a bursty counter gives high burstiness.
%     6. Settle gating: rows before cfg.settleTime never influence any
%        window.
%     7. The CSV regenerates byte-for-byte on rewrite.
%
%   This section previously lived inside tr36777SelfTest.m (D3.1 form);
%   it moved here when the Phase 4 signature added the scheduler and
%   traffic inputs, and tr36777SelfTest now covers channel maths only.

    addpath(fullfile(fileparts(mfilename('fullpath')), 'functions'));
    tol = 1e-6;
    fprintf('=== validateFeatureExtraction (D4.2) ===\n');

    %% Synthetic scenario: 2 UEs, 15 s of 10 ms scans, settle 0.5 s
    fakeNames = {'time','ueID','label_is_aerial','servingGNB','servingSINR', ...
        'numVisible','maxNeighbourSINR','meanNeighbourSINR','sinrSpread', ...
        'handoverCount','timeSinceLastHO'};
    t = (0.1:0.01:15)';
    mk = @(id, lbl, base) struct( ...
        'featureLog', [t, id*ones(size(t)), lbl*ones(size(t)), ...
            ones(size(t)), base + sin(t), 3*ones(size(t)), base - 3 + cos(t), ...
            base - 5 + 0*t, 8 + 0*t, cumsum(t > 7), max(t - 7, t)], ...
        'featureNames', {fakeNames}, ...
        'ueLabel', string(tern(lbl, "aerial", "terrestrial")), ...
        'handoverTimes', tern(lbl, 7.5, zeros(1,0)), ...
        'UE', struct('ID', 4 + (id - 4), 'Name', "UE-" + id));
    managers = {mk(4, 0, 20), mk(5, 1, 25)};

    cfg = struct('scenario', "UMa", 'seed', 42, 'windowLen', 10, ...
        'windowStride', 1, 'settleTime', 0.5, 'rntiOffset', -2, ...
        'outputDir', tempname);

    % Scheduler logs at one shared anchor gNB. RNTI = UE.ID + offset.
    rnti = [4 5] + cfg.rntiOffset;
    ts = (0.5:0.05:15)';                  % 20 Hz context snapshots
    n = numel(ts);
    % UE 1 (terrestrial): CQI constant 10; UE 2 (aerial): ramp 6 -> 12
    ctx = [ [ts, rnti(1)*ones(n,1), 10*ones(n,1), ones(n,1),  9*ones(n,1)]; ...
            [ts, rnti(2)*ones(n,1), 6 + (ts - ts(1))*(6/(ts(end)-ts(1))), ...
             ones(n,1), 14*ones(n,1)] ];
    % Grants: UE1 DL MCS constant 12, UL 7; UE2 DL alternating 10/14
    % (mean 12, var 4 with 1/N normalisation... var() uses N-1), UL 20.
    tg = (0.5:0.02:15)'; m2 = numel(tg);
    alt = repmat([10; 14], ceil(m2/2), 1); alt = alt(1:m2);
    grants = [ [tg, rnti(1)*ones(m2,1), zeros(m2,1), 12*ones(m2,1), 5*ones(m2,1)]; ...
               [tg, rnti(1)*ones(m2,1),  ones(m2,1),  7*ones(m2,1), 5*ones(m2,1)]; ...
               [tg, rnti(2)*ones(m2,1), zeros(m2,1),  alt,          5*ones(m2,1)]; ...
               [tg, rnti(2)*ones(m2,1),  ones(m2,1), 20*ones(m2,1), 5*ones(m2,1)] ];
    sched = struct('ctx', {{ctx}}, 'grants', {{grants}}, ...
        'anchorIdx', [1 1], 'rnti', rnti);

    % Traffic: UE1 steady DL-heavy 3000 B / 0.1 s DL, 300 B UL;
    % UE2 steady UL-heavy 5000 B / 0.1 s UL, 125 B DL. Then a bursty
    % variant for the burstiness check.
    tt = (0:0.1:15)'; ns = numel(tt);
    trafficLogs = { ...
        [tt, (0:ns-1)'*300,  (0:ns-1)'*3000, (0:ns-1)'*300,  (0:ns-1)'*3000], ...
        [tt, (0:ns-1)'*5000, (0:ns-1)'*125,  (0:ns-1)'*5000, (0:ns-1)'*125] };

    %% Run the real extraction
    T = extractWindowedFeatures(managers, cfg, sched, trafficLogs);

    %% 1. Schema and prefix contract
    check(isequal(T.Properties.VariableNames, phase4FeatureSchema()), ...
        'output columns equal the locked Phase 4 schema');
    p3 = phase3FeatureSchema();
    check(isequal(T.Properties.VariableNames(1:numel(p3)), p3), ...
        'Phase 3 schema is an exact prefix (append-only contract)');

    %% 2. Labels
    check(all(T.label(T.ueID == 5) == 1) && all(T.label(T.ueID == 4) == 0), ...
        'labels carried through');

    %% 3. CQI block
    r1 = T(T.ueID == 4, :); r2 = T(T.ueID == 5, :);
    check(all(abs(r1.cqi_mean - 10) < tol) && all(r1.cqi_var < tol) && ...
          all(abs(r1.cqi_trend_perS) < 1e-3), ...
        'constant CQI: mean 10, zero variance, zero trend');
    slope = 6 / (ts(end) - ts(1));   % CQI per second of the ramp
    check(all(abs(r2.cqi_trend_perS - slope) < 1e-3), ...
        sprintf('CQI ramp: recovered slope %.4f CQI/s', slope));

    %% 4. MCS block
    check(all(abs(r1.mcsDL_mean - 12) < tol) && all(r1.mcsDL_var < tol) && ...
          all(abs(r1.mcsUL_mean - 7) < tol), ...
        'constant MCS moments (DL 12, UL 7)');
    check(all(abs(r2.mcsDL_mean - 12) < 0.05) && ...
          all(abs(r2.mcsDL_var - 4) < 0.1) && ...
          all(abs(r2.mcsUL_mean - 20) < tol), ...
        'alternating DL MCS 10/14: mean 12, var 4; UL 20');

    %% 5. Traffic block
    % Steady 0.1 s increments: each 10 s window carries 100 increments.
    check(all(abs(r1.dlVol_bytes - 100*3000) < 3000) && ...
          all(abs(r1.ulVol_bytes - 100*300) < 300), ...
        'terrestrial volumes: about 300 kB DL, 30 kB UL per window');
    check(all(r1.dlulAsym > 0.8) && all(r2.dlulAsym < -0.8), ...
        'asymmetry signs: terrestrial DL-heavy (+), aerial UL-heavy (-)');
    check(all(r1.trafficBurstiness_cv < 0.05) && ...
          all(r2.trafficBurstiness_cv < 0.05), ...
        'steady streams: near-zero burstiness');
    check(all(abs(r1.thr_mean_bps - (100*3300*8/10)) < 3300*8), ...
        'throughput consistent with volumes/windowLen');
    % Bursty counter: 10x the bytes in every 10th interval, zero otherwise
    burst = zeros(ns,1); burst(1:10:end) = 30000; burstCum = cumsum(burst);
    tl2 = trafficLogs; tl2{1}(:,4:5) = [burstCum, burstCum];
    Tb = extractWindowedFeatures(managers, cfg, sched, tl2);
    check(all(Tb.trafficBurstiness_cv(Tb.ueID == 4) > 1), ...
        'bursty stream: coefficient of variation well above 1');

    %% 6. Settle gating
    check(all(T.winStart_s >= cfg.settleTime - tol), ...
        'no window starts before the settle cut-off');

    %% 7. Byte-identical CSV
    f1 = writeFeatureCSV(T, cfg); b1 = fileread(f1);
    f2 = writeFeatureCSV(T, cfg); b2 = fileread(f2);
    check(isequal(b1, b2), 'CSV byte-identical on rewrite');

    fprintf('All feature-extraction checks passed.\n');
end

%% local helpers
function check(cond, what)
    if cond
        fprintf('PASS  %s\n', what);
    else
        error('validateFeatureExtraction:fail', 'FAIL: %s', what);
    end
end

function out = tern(cond, a, b)
    if cond, out = a; else, out = b; end
end
