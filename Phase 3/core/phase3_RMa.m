%% phase3_RMa.m  -  D3.3: RMa terrestrial + TR 36.777 RMa-AV aerial overlay
% Required second scenario: rural / isolated protected sites.
%
% Terrestrial model: TR 38.901 RMa. Aerial overlay: TR 36.777 RMa-AV
% (Tables B-1, B-2, B-3 and Annex B.1.1 Alternative 1, CDL-D based).
% Differences from the UMa fork are confined to this configuration script
% (per the Phase 3 folder rule): the z-boundary, the Table B.1.1-1
% parameter set, the ground-reflection ZOD offset (selected inside
% createScenarioChannels by cfg.scenario), gNB height/spacing, and wider
% mobility bounds. The pipeline, channel builder, feature extraction, and
% CSV schema are shared with phase3_UMa.m unchanged.

clc; clear;

cfg = struct();
cfg.scenario = "RMa";
cfg.seed = 42;                      % fixed seed: CSV must regenerate identically

% --- TR 36.777 Annex B.1: RMa-AV overlay applies 10 m to 300 m ----------
% Notably lower than the UMa/UMi 22.5 m floor.
cfg.zBoundary = 10;

% --- Table B.1.1-1 (RMa-AV), values verified against the source ---------
cfg.av.los  = struct('ASA',0.2, 'ASD',0.2, 'ZSA',0.1, 'ZSD',0.1, ...
                     'K_dB',20, 'DS_s',10e-9);
cfg.av.nlos = struct('ASA',0.5, 'ASD',0.5, 'ZSA',0.2, 'ZSD',0.2, ...
                     'K_dB',10, 'DS_s',30e-9);

% --- ZOD offset geometry (Annex B.1.1 Step 5, eq B.1.1-1) ----------------
% Ground specular reflection; no building term for RMa-AV, so this field
% is unused by the RMa branch of createScenarioChannels.
cfg.avgBuildingHeight = NaN;

% --- Radio / geometry -----------------------------------------------------
cfg.carrierFrequency = 2.6e9;       % kept from Phase 2 for dataset continuity
                                    % (TR 36.777 RMa-AV calibration used
                                    % 700 MHz; RMa pathloss valid to 7 GHz;
                                    % logged as a deliberate deviation)
spacing = 1200;                     % wider rural inter-site spacing
cfg.gNBPositions = [ ...
    spacing/2  spacing  35;         % 35 m gNB height: RMa assumption
    spacing    0        35;         % (TR 36.777 Table B-1 Note 1)
    0          0        35];

cfg.uePositions = [ ...
    -6   100  1.5;                  % terrestrial UEs
    -32  20   1.5;
    80   350  1.5;
    122  220  1.5;
    110  413  1.5;
    200  0    100;                  % aerial UEs (inside the 10-300 m band)
    -50  130  120];
cfg.ueIsAerial = logical([0 0 0 0 0 1 1]);

% --- Mobility --------------------------------------------------------------
cfg.enableMobility = true;
cfg.aerialSpeedRange      = [30 50];
cfg.terrestrialSpeedRange = [1 5];
cfg.aerialBounds      = [600 600 3000 3000];
cfg.terrestrialBounds = [600 600 3000 3000];

% --- Traffic / measurement -------------------------------------------------
cfg.appDataRate  = 1e3;
cfg.rntiOffset   = -2;
cfg.visThreshold = 0;

% --- D3.1 windowing (identical to UMa so CSVs concatenate cleanly) ---------
cfg.simulationTime = 30;
cfg.windowLen      = 10;
cfg.windowStride   = 1;
cfg.settleTime     = 1;             % s; discard scans/handovers before this
                                    % (initial attach is distance-based, so the
                                    % first scans give bad data; see deviations log)

% --- Options ---------------------------------------------------------------
cfg.enableShadowFading = false;
cfg.enableReplay = false;

results = phase3_Pipeline(cfg);     %#ok<NASGU>
