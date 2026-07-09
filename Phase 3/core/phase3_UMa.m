%% phase3_UMa.m  -  D3.2: UMa terrestrial + TR 36.777 UMa-AV aerial overlay
% Primary scenario for the interim oral dataset (dominant UK deployment
% context for the protected-site types in scope: military bases, power
% plants, most stations).
%
% Terrestrial model: TR 38.901 UMa (pathloss via nrPathLoss, LOS
% probability via Table 7.4.2-1). Aerial overlay: TR 36.777 UMa-AV
% (Tables B-1, B-2, B-3 and Annex B.1.1 Alternative 1, CDL-D based).
%
% All TR-derived values below cite their source table; see the deviations
% log for every point where a source value is read or adapted.

clc; clear;

cfg = struct();
cfg.scenario = "UMa";
cfg.seed = 1;                      % fixed seed: CSV must regenerate identically

% --- TR 36.777 Annex B.1: UMa-AV overlay applies 22.5 m to 300 m --------
cfg.zBoundary = 22.5;               % m AGL; below this the aerial UE class
                                    % still uses terrestrial TR 38.901 UMa

% --- Table B.1.1-2 (UMa-AV), values verified against the source ---------
%                  ASA   ASD   ZSA   ZSD   K(dB)  DS(s)
cfg.av.los  = struct('ASA',0.5, 'ASD',0.5, 'ZSA',0.1, 'ZSD',0.1, ...
                     'K_dB',20, 'DS_s',10e-9);
cfg.av.nlos = struct('ASA',1,   'ASD',1,   'ZSA',0.3, 'ZSD',0.3, ...
                     'K_dB',10, 'DS_s',30e-9);

% --- ZOD offset geometry (Annex B.1.1 Step 5, eq B.1.1-2) ----------------
% Rooftop specular reflection; h is the average building height. 20 m is
% the TR 38.901 UMa average-rooftop working assumption (deviations log).
cfg.avgBuildingHeight = 20;

% --- Radio / geometry -----------------------------------------------------
cfg.carrierFrequency = 2.6e9;       % kept from Phase 2 for dataset continuity
                                    % (TR 36.777 calibration used 2 GHz; logged)
spacing = 500;
cfg.gNBPositions = [ ...
    spacing/2  spacing  25;         % 25 m gNB height: UMa assumption
    spacing    0        25;         % (TR 36.777 Table B-1 Note 1)
    0          0        25];

cfg.uePositions = [ ...
    -6   100  1.5;                  % terrestrial UEs
    -32  20   1.5;
    200  0    100;                  % aerial UEs (inside the 22.5-300 m band)
    -50  130  120];
cfg.ueIsAerial = logical([0 0 1 1]);   % ground truth, label 0/1

% --- Mobility --------------------------------------------------------------
cfg.enableMobility = true;
cfg.aerialSpeedRange      = [30 50];
cfg.terrestrialSpeedRange = [1 5];
cfg.aerialBounds      = [350 475 1500 1450];   % x centre, y centre, w, h
cfg.terrestrialBounds = [350 475 1500 1450];

% --- Traffic / measurement -------------------------------------------------
cfg.appDataRate  = 1e3;
cfg.rntiOffset   = -2;              % RNTI calibration (SLS library ID bug)
cfg.visThreshold = 0;               % dB; gNB counts as visible above this

% --- D3.1 windowing --------------------------------------------------------
cfg.simulationTime = 30.5;            % s; must exceed windowLen for real windows
cfg.windowLen      = 10;            % s (per-UE sliding window)
cfg.windowStride   = 1;             % s
cfg.settleTime     = 0.5;             % s; discard scans/handovers before this
                                    % (initial attach is distance-based, so the
                                    % first scans give bad data; see deviations log)

% --- Options ---------------------------------------------------------------
cfg.enableShadowFading = true;     % deterministic runs by default (logged)
cfg.enableReplay = true;

results = phase3_Pipeline(cfg);     
