function results = validatePhase4EndToEnd(checkRepro)
%validatePhase4EndToEnd Smoke test of the full Phase 4 pipeline (D4.1+D4.2).
%
%   RESULTS = validatePhase4EndToEnd() runs a short (4 s) UMa scenario
%   through the REAL phase4_Pipeline: TR 36.777/38.901 channels, SRS
%   measurement, mobility chain, CQI/MCS-logging schedulers, per-class
%   traffic, windowed extraction, CSV export. This exercises every layer
%   the full scenarios use (the Phase 1/2 object model and handover logic
%   included), just briefly, so expect a few minutes of wall time. Checks:
%     1. The run completes and the CSV exists with the Phase 4 schema.
%     2. Every UE produced feature rows.
%     3. The CQI/MCS columns are not all-NaN (scheduler logging worked
%        end-to-end through the real CSI reporting chain).
%     4. Aggregate traffic per class has the designed asymmetry sign
%        (aerial UL-heavy, terrestrial DL-heavy). Aggregates are used
%        rather than per-window values because a 2 s window can fall
%        entirely in a terrestrial Off period.
%     5. The per-scan SINR logs and handover managers populated (Phase 3
%        measurement path still intact under the Phase 4 scheduler).
%
%   RESULTS = validatePhase4EndToEnd(true) additionally runs the whole
%   scenario a SECOND time and checks the CSV regenerates byte-for-byte
%   (the fixed-seed reproducibility contract). Doubles the wall time.
%
%   The 2 s window here is a smoke-test setting; it does not touch the
%   10 s windows of the real scenario scripts, and the CSV goes to a
%   temporary folder so no dataset in data/ is overwritten.

    if nargin < 1, checkRepro = false; end
    addpath(fullfile(fileparts(mfilename('fullpath')), 'functions'));
    fprintf('=== validatePhase4EndToEnd ===\n');

    cfg = smokeConfig();
    results = phase4_Pipeline(cfg);
    T = results.featureTable;

    check(exist(results.csvPath, 'file') == 2, 'CSV written');
    check(isequal(T.Properties.VariableNames, phase4FeatureSchema()), ...
        'CSV columns equal the locked Phase 4 schema');
    check(numel(unique(T.ueID)) == numel(results.UEs), ...
        sprintf('feature rows present for all %d UEs', numel(results.UEs)));

    check(any(~isnan(T.cqi_mean)) || any(~isnan(T.mcsDL_mean)), ...
        'CQI/MCS columns carry data (scheduler logging worked in-network)');
    if all(isnan(T.cqi_mean))
        fprintf(['CHECK   cqi_mean is all-NaN: run phase4SchedulerCheck and\n' ...
                 '        inspect the C2 layout dump before generating datasets.\n']);
    end

    aer = T.label == 1; ter = T.label == 0;
    ulA = sum(T.ulVol_bytes(aer), 'omitnan'); dlA = sum(T.dlVol_bytes(aer), 'omitnan');
    ulT = sum(T.ulVol_bytes(ter), 'omitnan'); dlT = sum(T.dlVol_bytes(ter), 'omitnan');
    check(ulA > dlA, sprintf('aerial aggregate UL-heavy (UL %d B > DL %d B)', ...
        round(ulA), round(dlA)));
    check(dlT > ulT, sprintf('terrestrial aggregate DL-heavy (DL %d B > UL %d B)', ...
        round(dlT), round(ulT)));

    scans = cellfun(@(m) size(m.featureLog, 1), results.managers);
    check(all(scans > 0), sprintf('per-scan SINR logs populated (%s scans)', ...
        strtrim(sprintf('%d ', scans))));

    if checkRepro
        fprintf('--- reproducibility: second identical run ---\n');
        b1 = fileread(results.csvPath);
        r2 = phase4_Pipeline(smokeConfig());
        b2 = fileread(r2.csvPath);
        check(isequal(b1, b2), 'CSV byte-identical across two seeded runs');
    end

    fprintf('End-to-end smoke test passed.\n');
end

%% local helpers
function cfg = smokeConfig()
%smokeConfig The phase4_UMa configuration shrunk to a 4 s smoke run.
    cfg = struct();
    cfg.scenario = "UMa";
    cfg.seed = 42;
    cfg.zBoundary = 22.5;
    cfg.av.los  = struct('ASA',0.5, 'ASD',0.5, 'ZSA',0.1, 'ZSD',0.1, ...
                         'K_dB',20, 'DS_s',10e-9);
    cfg.av.nlos = struct('ASA',1,   'ASD',1,   'ZSA',0.3, 'ZSD',0.3, ...
                         'K_dB',10, 'DS_s',30e-9);
    cfg.avgBuildingHeight = 20;
    cfg.carrierFrequency = 2.6e9;
    spacing = 500;
    cfg.gNBPositions = [spacing/2 spacing 25; spacing 0 25; 0 0 25];
    cfg.uePositions = [-6 100 1.5; -32 20 1.5; 200 0 100; -50 130 120];
    cfg.ueIsAerial = logical([0 0 1 1]);
    cfg.enableMobility = true;
    cfg.aerialSpeedRange      = [30 50];
    cfg.terrestrialSpeedRange = [1 5];
    cfg.aerialBounds      = [350 475 1500 1450];
    cfg.terrestrialBounds = [350 475 1500 1450];
    cfg.traffic.aerial.ul      = tspec(4000, Inf, 0,   1250);
    cfg.traffic.aerial.dl      = tspec( 100, Inf, 0,   1250);
    cfg.traffic.terrestrial.dl = tspec(2000, 1,   2,   1500);
    cfg.traffic.terrestrial.ul = tspec( 200, 0.5, 2.5,  500);
    cfg.rntiOffset   = -2;
    cfg.visThreshold = 0;
    cfg.simulationTime = 4;      % smoke run
    cfg.windowLen      = 2;      % smoke window; real scripts use 10 s
    cfg.windowStride   = 1;
    cfg.settleTime     = 0.5;
    cfg.enableShadowFading = true;
    cfg.enableReplay = false;
    cfg.outputDir = fullfile(tempdir, 'phase4_smoke');   % keep data/ clean
end

function s = tspec(kbps, on, off, pkt)
    s = struct('dataRate_kbps', kbps, 'onTime_s', on, ...
               'offTime_s', off, 'packetSize_B', pkt);
end

function check(cond, what)
    if cond
        fprintf('PASS  %s\n', what);
    else
        error('validatePhase4EndToEnd:fail', 'FAIL: %s', what);
    end
end
