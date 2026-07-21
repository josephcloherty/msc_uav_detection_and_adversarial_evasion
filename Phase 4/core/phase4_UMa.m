%% phase4_UMa.m  -  D4.1/D4.2: UMa scenario with CQI/MCS logging + per-class traffic
% Primary scenario. Radio configuration (channel models, geometry,
% mobility, windowing, measurement chain) is carried over from
% phase3_UMa.m unchanged so the Phase 3 feature columns stay directly
% comparable; the Phase 4 additions are the per-gNB CQI/MCS-logging
% scheduler (inside phase4_Pipeline) and the per-class traffic block
% below.
%
% All TR-derived values cite their source table; see the deviations log
% for every point where a source value is read or adapted.

clc; clear;
addpath(fullfile(fileparts(mfilename('fullpath')), 'functions'));   % auxiliary functions live in core/functions

cfg = struct();
cfg.scenario = "UMa";
cfg.seed = 42;                      % fixed seed: CSV must regenerate identically

% --- TR 36.777 Annex B.1: UMa-AV overlay applies 22.5 m to 300 m --------
cfg.zBoundary = 22.5;

% --- Table B.1.1-2 (UMa-AV), values verified against the source ---------
cfg.av.los  = struct('ASA',0.5, 'ASD',0.5, 'ZSA',0.1, 'ZSD',0.1, ...
                     'K_dB',20, 'DS_s',10e-9);
cfg.av.nlos = struct('ASA',1,   'ASD',1,   'ZSA',0.3, 'ZSD',0.3, ...
                     'K_dB',10, 'DS_s',30e-9);

% --- ZOD offset geometry (Annex B.1.1 Step 5, eq B.1.1-2) ----------------
cfg.avgBuildingHeight = 20;

% --- Radio / geometry -----------------------------------------------------
cfg.carrierFrequency = 2.6e9;       % kept from Phase 2 for dataset continuity
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

% --- D4.1 per-class traffic profiles ---------------------------------------
% Replaces the Phase 3 identical 1 Mbps constant streams (deviations log:
% per-class traffic is deliberate in Phase 4; DL/UL asymmetry and
% burstiness are themselves operator-observable features under study, and
% traffic reshaping is a Q3 evasion action).
% Aerial UE: uplink-heavy video-streaming drone. UL 4 Mbps steady (live
% video in the 2-6 Mbps range reported in the LTE UAV measurement
% literature). DL is the TR 36.777 command-and-control traffic model
% verified against the source document: "C&C: 60-100 kbps for UL/DL",
% packets of 1250 bytes arriving periodically every 100 ms; 100 kbps at
% 1250 B reproduces that period exactly. Steady UL, so LOW burstiness is
% part of the aerial signature.
% Terrestrial UE: downlink-heavy bursty profile (browsing/short video
% chunks): DL 2 Mbps in 1 s bursts every 3 s, UL 200 kbps request/ack
% bursts. All On/Off periods are fixed scalars: deterministic sources,
% byte-reproducible runs.
%                          kbps   on(s)  off(s)  pkt(B)
cfg.traffic.aerial.ul      = spec(4000,  Inf,   0,     1250);
cfg.traffic.aerial.dl      = spec( 100,  Inf,   0,     1250);
cfg.traffic.terrestrial.dl = spec(2000,  1,     2,     1500);
cfg.traffic.terrestrial.ul = spec( 200,  0.5,   2.5,    500);

% --- Measurement -----------------------------------------------------------
cfg.rntiOffset   = -2;              % RNTI calibration (SLS library ID bug)
cfg.visThreshold = 0;               % dB; gNB counts as visible above this

% --- Windowing (identical to Phase 3 so datasets stay comparable) ----------
cfg.simulationTime = 30.5;          % s; must exceed windowLen for real windows
cfg.windowLen      = 10;            % s (per-UE sliding window)
cfg.windowStride   = 1;             % s
cfg.settleTime     = 0.5;           % s; discard scans/handovers before this

% --- Options ---------------------------------------------------------------
cfg.enableShadowFading = true;
cfg.enableReplay = true;

results = phase4_Pipeline(cfg);

%% local
function s = spec(kbps, on, off, pkt)
    s = struct('dataRate_kbps', kbps, 'onTime_s', on, ...
               'offTime_s', off, 'packetSize_B', pkt);
end
