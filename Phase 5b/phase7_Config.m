function cfg = phase7_Config()
%phase7_Config Every tunable value for the Phase 7 pipeline.
%
%   CFG = phase7_Config() returns the full parameter set.
%
%   Edit this file to change the dataset. phase7_RunBatch reads it,
%   phase7_ScenarioGen expands it into one run config per seed, and
%   phase7_Pipeline consumes that.
%
%   The scenario fixes the topology. The seed fixes UE placement, aerial UE
%   count, mobility, traffic jitter, LOS and shadow-fading draws, channel
%   seeds and handover measurement error, so the same seed and scenario give
%   an identical run.

    cfg = struct();

    cfg.batch = struct();

    % The Phase 5 honest hold-out; the classifier is frozen on seeds 1 to 45.
    cfg.batch.seedRange = 46:60;

    % Keyed to the seed, not the run index, so seed 46 stays on UMa however
    % the runs are enumerated.
    cfg.batch.scenarioCycle = ["UMa", "RMa", "UMi"];

    % Applies to the full condition-by-seed list, not to the seed range.
    cfg.batch.maxRuns = Inf;

    % Overlays are applied by applyEvasion in phase7_RunBatch; these are just
    % the names it dispatches on.
    cfg.evasion = struct();
    cfg.evasion.conditions = ["lowAltitude", "trafficReshaping", "combined"];

    % 15 m sits below the TR 36.777 overlay floor in UMa/UMi (22.5 m) but
    % above it in RMa (10 m), so the scenarios are deliberately asymmetric.
    cfg.evasion.lowAltitude_m = 15;

    % Set by applyEvasion, never by hand. Lets the generator accept an aerial
    % band below the overlay floor, which is refused for honest runs.
    cfg.evasion.allowSubBoundary = false;

    % Each worker holds one full simulation, so memory scales with this.
    cfg.batch.numWorkers = [45];

    % Manifest filename label, "" for a yyyymmdd_HHMMSS stamp.
    cfg.batch.tag = "";

    % Output directory, "" resolves to <Phase 7>/data.
    cfg.batch.dataDir = "";

    cfg.batch.skipExisting = true;
    cfg.batch.continueOnError = true;
    cfg.batch.verboseWorkers = false;

    % Prior only; phase7_CostModel prefers measurements in
    % data/costmodel_measured.csv when they exist.
    cfg.batch.costModel = struct('sPerSimSecPerGNBPerUE', 33.6);

    cfg.batch.poolRetries       = 2;     % extra attempts per size and range
    cfg.batch.poolRetryWait_s   = 15;    % pause between attempts
    cfg.batch.allowFewerWorkers = true;  % halve and retry rather than abort

    % [] keeps the default, 0 asks for ephemeral ports, a pair is an explicit
    % range. Blocked ranges on Windows:
    %   netsh int ipv4 show excludedportrange protocol=tcp
    cfg.batch.poolPortRanges = {[], 0, [40000 41000], [21000 22000]};

    cfg.progress = struct();
    % false drops the throttled aggregate lines but keeps per-run and DONE.
    cfg.progress.enable        = true;
    % Also sets how often each run's ETA is re-estimated.
    cfg.progress.updatesPerRun = 100;
    % Weight on the newest rate sample: higher tracks change but is noisier.
    cfg.progress.rateAlpha     = 0.35;
    cfg.progress.minPrint_s    = 5;

    % Held at the Phase 2-4 values so the dataset stays comparable.
    cfg.radio = struct();
    cfg.radio.carrierFrequency  = 2.6e9;   % Hz
    cfg.radio.channelBandwidth  = 20e6;    % Hz
    cfg.radio.subcarrierSpacing = 30e3;    % Hz
    cfg.radio.duplexMode        = "TDD";
    cfg.radio.gnbTxAntennas     = 16;
    cfg.radio.gnbRxAntennas     = 8;
    cfg.radio.gnbReceiveGain    = 11;      % dB
    cfg.radio.ueTxAntennas      = 4;
    cfg.radio.ueRxAntennas      = 2;
    cfg.radio.ueReceiveGain     = 11;      % dB

    cfg.population = struct();
    cfg.population.numTerrestrialUE = 8;
    cfg.population.pMultiAerial = 0.5;
    cfg.population.singleAerialCount = 1;
    % Inclusive [min max], drawn uniformly. Gives an aerial fraction of
    % 11% to 43% with the values above.
    cfg.population.aerialSwarmSizeRange = [2 6];

    cfg.mobility = struct();
    cfg.mobility.enable = true;
    cfg.mobility.aerialSpeedRange      = [15 30];   % m/s, random waypoint
    cfg.mobility.terrestrialSpeedRange = [1 5];     % m/s

    % How addMobility reads the Bounds vector: "centre" is
    % [xCentre yCentre width height], "corner" is [xMin yMin width height].
    cfg.mobility.boundsConvention = "centre";

    %                                kbps   on(s)  off(s)  pkt(B)
    cfg.traffic = struct();
    cfg.traffic.aerial.ul      = trafficSpec(4000,  Inf,  0,    1250);
    cfg.traffic.aerial.dl      = trafficSpec( 100,  Inf,  0,    1250);
    cfg.traffic.terrestrial.dl = trafficSpec(2000,  1,    2,    1500);
    cfg.traffic.terrestrial.ul = trafficSpec( 200,  0.5,  2.5,   500);

    % Drawn once per run then frozen. 0.15 scales each rate by [0.85 1.15].
    cfg.traffic.rateJitterFrac   = 0.15;
    cfg.traffic.timingJitterFrac = 0.20;   % applies to finite On/Off times

    cfg.measurement = struct();
    cfg.measurement.visThreshold = 0;    % dB; gNB counts as visible above this

    % SRS events identify a UE as UE.ID + rntiOffset. Empirical, and a wrong
    % value fails silently with every SINR column NaN. Not the scheduler RNTI.
    cfg.measurement.rntiOffset = -2;

    % Checked against real SRS events at settle time, inside the span the
    % extraction discards anyway.
    cfg.measurement.verifyRNTI = true;

    % false aborts and names the right offset, true patches the managers in
    % place and warns.
    cfg.measurement.autoCorrectRNTI = false;

    cfg.measurement.printRNTIMap = true;

    % TR 36.777 Table A.2.1-1 baselines. Changing any of them changes the
    % handover features, so rows across different values are not comparable.
    cfg.handover = struct();
    cfg.handover.useTr36777Mobility = true;   % false = legacy instant A3
    cfg.handover.a3Offset      = 2;      % dB, A3Offset
    cfg.handover.ttt           = 0.160;  % s, TimeToTrigger
    cfg.handover.l1WindowSec   = 0.200;  % s, L1 linear filtering window
    cfg.handover.l3K           = 1;      % L3RRMCoefficient k
    cfg.handover.hoPrepDelay   = 0.050;  % s
    cfg.handover.hoExecDelay   = 0.040;  % s
    cfg.handover.measErrStd    = 1.22;   % dB, decision-chain measurement error
    cfg.handover.mtsPingPong   = 1;      % s, minimum time of stay
    cfg.handover.hysteresis    = 1;      % dB, legacy instant-A3 margin
    cfg.handover.sinrThreshold = 20;     % dB, A5 threshold
    % scanPeriod and scanStartTime do not belong here: handoverManager
    % schedules its scan in the constructor and would ignore them.

    % These define the features, so changing them makes rows incomparable with
    % earlier CSVs. simulationTime is cut from the Phase 5 60.5 s; the other
    % three are held, so the feature vector is unchanged and only the row
    % count per UE-run falls (50 to 30, independent windows 5 to 3). The
    % honest comparator must be recomputed from the first 30 windows of each
    % Phase 5 hold-out UE-run to match.
    cfg.window = struct();
    cfg.window.simulationTime = 40.5;   % s; must exceed windowLen
    cfg.window.windowLen      = 10;     % s, per-UE sliding window
    cfg.window.windowStride   = 1;      % s
    cfg.window.settleTime     = 0.5;    % s, discarded attach/handover burst

    cfg.channel = struct();
    cfg.channel.enableShadowFading = true;

    % true evaluates LOS/NLOS per packet from a spatially consistent random
    % field (TR 38.901 clause 7.6.3.1); false freezes it at the initial
    % positions, which is Phase 4 behaviour.
    cfg.channel.dynamicLOS = true;

    % m; [] uses the TR 38.901 Table 7.6.3.1-2 value (50 UMa/UMi, 60 RMa).
    cfg.channel.losCorrelationDistance_m = [];

    cfg.replay = struct();
    cfg.replay.save = true;             % one replay .mat per run
    cfg.replay.format = "-v7.3";        % needed above the 2 GB v7 limit
    cfg.replay.includeNodes = true;     % false shrinks the file but the
                                        % replay then draws no node marks
    cfg.replay.cullTime = [];           % s; [] culls the settle span only

    % Every UE holds an uplink to every gNB, so the per-gNB UE count equals
    % the total UE count and the default SRS configuration caps it at 16.
    cfg.srs = struct();
    cfg.srs.maxUEsPerGNB = 16;
    % Slots; [] for the toolbox default. The documented route past the 16-UE
    % limit, so log it when used.
    cfg.srs.periodicitySlots = [];

    cfg.scenarios = struct();

    % UMa: primary deployment scenario
    s = struct();
    s.zBoundary = 22.5;                 % TR 36.777 Annex B.1: UMa-AV from 22.5 m
    s.avgBuildingHeight = 20;           % m, rooftop reflection (eq B.1.1-2)
    % Table B.1.1-2 (UMa-AV)
    s.av.los  = struct('ASA',0.5,'ASD',0.5,'ZSA',0.1,'ZSD',0.1, ...
                       'K_dB',20,'DS_s',10e-9);
    s.av.nlos = struct('ASA',1,  'ASD',1,  'ZSA',0.3,'ZSD',0.3, ...
                       'K_dB',10,'DS_s',30e-9);
    s.aerialChannelBuilder = "";        % CDL-D based, no fork builder needed
    s.topology = struct('numGNB', 5, ...            % centre site plus a ring of 4
                        'siteRadius_m', 750, ...    % site span 2*radius = 1500 m
                        'gnbHeight_m', 25, ...      % TR 36.777 Table B-1 Note 1
                        'ueAreaSpan_m', 2200, ...   % square UE region, 2.2 km
                        'originOffset_m', [0 0]);
    s.terrestrialAlt_m  = 1.5;
    s.aerialAltRange_m  = [40 200];     % above zBoundary, below the 300 m cap
    cfg.scenarios.UMa = s;

    % RMa: rural and isolated protected sites
    s = struct();
    s.zBoundary = 10;                   % RMa-AV applies from 10 m
    s.avgBuildingHeight = NaN;          % ground reflection (eq B.1.1-1)
    % Table B.1.1-1 (RMa-AV)
    s.av.los  = struct('ASA',0.2,'ASD',0.2,'ZSA',0.1,'ZSD',0.1, ...
                       'K_dB',20,'DS_s',10e-9);
    s.av.nlos = struct('ASA',0.5,'ASD',0.5,'ZSA',0.2,'ZSD',0.2, ...
                       'K_dB',10,'DS_s',30e-9);
    s.aerialChannelBuilder = "";
    s.topology = struct('numGNB', 5, ...
                        'siteRadius_m', 1500, ...   % site span 3000 m
                        'gnbHeight_m', 25, ...
                        'ueAreaSpan_m', 3600, ...
                        'originOffset_m', [0 0]);
    s.terrestrialAlt_m  = 1.5;
    s.aerialAltRange_m  = [40 200];
    cfg.scenarios.RMa = s;

    % UMi: street-level dense urban
    s = struct();
    s.zBoundary = 22.5;
    s.avgBuildingHeight = NaN;          % unused; the fork builder owns the geometry
    s.av = [];                          % UMi-AV Alternative 1 is not CDL-D based
    s.aerialChannelBuilder = "buildUMiAVChannel";
    s.topology = struct('numGNB', 5, ...
                        'siteRadius_m', 400, ...
                        'gnbHeight_m', 10, ...      % street-level UMi site height
                        'ueAreaSpan_m', 1200, ...
                        'originOffset_m', [0 0]);
    s.terrestrialAlt_m  = 1.5;
    s.aerialAltRange_m  = [40 150];
    cfg.scenarios.UMi = s;
end

function s = trafficSpec(kbps, on, off, pkt)
%trafficSpec One networkTrafficOnOff specification.
    s = struct('dataRate_kbps', kbps, 'onTime_s', on, ...
               'offTime_s', off, 'packetSize_B', pkt);
end
