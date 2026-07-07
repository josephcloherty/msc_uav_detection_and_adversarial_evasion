%% phase3_UMi.m  -  D3.4 (optional): UMi Street Canyon + TR 36.777 UMi-AV overlay
% City-centre-interchange exception case. Run with the core folder on the
% MATLAB path (this fork lives in its own folder because its aerial fast
% fading is structurally different from the CDL-D forks):
%
%   addpath(fullfile('..','core'));
%
% Terrestrial model: TR 38.901 UMi - Street Canyon. Aerial overlay:
% TR 36.777 UMi-AV (Tables B-1, B-2, B-3). Aerial fast fading: the
% "reverse UMa" model of Annex B.1.1 (final paragraph) - the full clause
% 7.5 cluster-generation model with the BS and UE angular spreads
% interchanged, implemented in buildUMiAVChannel. This CORRECTS the
% earlier project documentation, which described UMi-AV as CDL-D based;
% the correction is recorded in the deviations log.
%
% z-boundary: 22.5 m per Annex B.1 (same floor as UMa-AV). This
% supersedes the earlier 20 m working assumption; 22.5 m is the
% spec-derived value (deviations log).

clc; clear;
addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'core'));

cfg = struct();
cfg.scenario = "UMi";
cfg.seed = 42;                      % fixed seed: CSV must regenerate identically

% --- TR 36.777 Annex B.1: UMi-AV overlay applies 22.5 m to 300 m --------
cfg.zBoundary = 22.5;

% --- Aerial fast fading: reverse-UMa clause 7.5 builder ------------------
cfg.aerialChannelBuilder = @buildUMiAVChannel;
% (cfg.av is not used by this fork; the builder draws its parameters from
% TR 38.901 Table 7.5-6 / 7.5-8 UMi columns with the spreads interchanged.)

% --- ZOD offset: not applicable (the CDL-D Step 5 offset belongs to the
%     UMa-AV/RMa-AV procedure; UMi-AV reuses the clause 7.5 model where
%     the NLOS ZOD offset comes from Table 7.5-8) -------------------------
cfg.avgBuildingHeight = NaN;

% --- Radio / geometry -----------------------------------------------------
cfg.carrierFrequency = 2.6e9;
spacing = 200;                      % dense street-canyon inter-site spacing
cfg.gNBPositions = [ ...
    spacing/2  spacing  10;         % 10 m gNB height: UMi assumption
    spacing    0        10;         % (TR 36.777 Table B-1 Note 1)
    0          0        10];

cfg.uePositions = [ ...
    -6   100  1.5;                  % terrestrial UEs
    -32  20   1.5;
    80   150  1.5;
    122  120  1.5;
    110  180  1.5;
    100  50   100;                  % aerial UEs (inside the 22.5-300 m band)
    -50  130  60];
cfg.ueIsAerial = logical([0 0 0 0 0 1 1]);

% --- Mobility --------------------------------------------------------------
cfg.enableMobility = true;
cfg.aerialSpeedRange      = [30 50];
cfg.terrestrialSpeedRange = [1 5];
cfg.aerialBounds      = [100 100 700 700];
cfg.terrestrialBounds = [100 100 700 700];

% --- Traffic / measurement -------------------------------------------------
cfg.appDataRate  = 1e3;
cfg.rntiOffset   = -2;
cfg.visThreshold = 0;

% --- D3.1 windowing (identical schema and windowing to UMa/RMa) ------------
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
