%% phase4_RMa.m  -  D4.1/D4.2: RMa scenario with CQI/MCS logging + per-class traffic
% Required second scenario (rural / isolated protected sites). Radio
% configuration carried over from phase3_RMa.m unchanged; Phase 4 adds
% the CQI/MCS-logging scheduler (inside phase4_Pipeline) and the same
% per-class traffic block as phase4_UMa.m, so traffic profiles are
% identical ACROSS SCENARIOS and the two CSVs concatenate cleanly.

clc; clear;

cfg = struct();
cfg.scenario = "RMa";
cfg.seed = 42;                      % fixed seed: CSV must regenerate identically

% --- TR 36.777 Annex B.1: RMa-AV overlay applies 10 m to 300 m ----------
cfg.zBoundary = 10;

% --- Table B.1.1-1 (RMa-AV), values verified against the source ---------
cfg.av.los  = struct('ASA',0.2, 'ASD',0.2, 'ZSA',0.1, 'ZSD',0.1, ...
                     'K_dB',20, 'DS_s',10e-9);
cfg.av.nlos = struct('ASA',0.5, 'ASD',0.5, 'ZSA',0.2, 'ZSD',0.2, ...
                     'K_dB',10, 'DS_s',30e-9);

% --- ZOD offset geometry (Annex B.1.1 Step 5, eq B.1.1-1) ----------------
cfg.avgBuildingHeight = NaN;        % ground reflection; no building term

% --- Radio / geometry -----------------------------------------------------
cfg.carrierFrequency = 2.6e9;       % kept from Phase 2 for dataset continuity
spacing = 1200;                     % wider rural inter-site spacing
cfg.gNBPositions = [ ...
    spacing/2  spacing  25;
    spacing    0        25;
    0          0        25];

cfg.uePositions = [ ...
    1070 1100  1.5;                 % terrestrial UEs
    320  200   1.5;
    700  0     80;                  % aerial UEs (above the 10 m RMa floor)
    -50  800   120];
cfg.ueIsAerial = logical([0 0 1 1]);   % ground truth, label 0/1

% --- Mobility --------------------------------------------------------------
cfg.enableMobility = true;
cfg.aerialSpeedRange      = [30 50];
cfg.terrestrialSpeedRange = [1 5];
cfg.aerialBounds      = [600 600 3000 3000];
cfg.terrestrialBounds = [600 600 3000 3000];

% --- D4.1 per-class traffic profiles (identical to phase4_UMa.m) ----------
%                          kbps   on(s)  off(s)  pkt(B)
cfg.traffic.aerial.ul      = spec(4000,  Inf,   0,     1250);
cfg.traffic.aerial.dl      = spec( 100,  Inf,   0,     1250);
cfg.traffic.terrestrial.dl = spec(2000,  1,     2,     1500);
cfg.traffic.terrestrial.ul = spec( 200,  0.5,   2.5,    500);

% --- Measurement -----------------------------------------------------------
cfg.rntiOffset   = -2;
cfg.visThreshold = 0;

% --- Windowing (identical to phase4_UMa.m so CSVs concatenate cleanly) -----
cfg.simulationTime = 30.5;
cfg.windowLen      = 10;
cfg.windowStride   = 1;
cfg.settleTime     = 0.5;

% --- Options ---------------------------------------------------------------
cfg.enableShadowFading = true;
cfg.enableReplay = true;

results = phase4_Pipeline(cfg);

%% local
function s = spec(kbps, on, off, pkt)
    s = struct('dataRate_kbps', kbps, 'onTime_s', on, ...
               'offTime_s', off, 'packetSize_B', pkt);
end
