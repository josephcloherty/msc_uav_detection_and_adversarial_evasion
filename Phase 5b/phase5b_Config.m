function cfg = phase5b_Config()
%phase5b_Config Every tunable value for the Phase 5b pipeline.
%
%   CFG = phase5b_Config() returns the full parameter set.
%
%   Edit this file to change the dataset. phase5b_RunBatch reads it,
%   phase5b_ScenarioGen expands it into one run config per seed, and
%   phase5b_Pipeline consumes that.
%
%   Phase 5b is the Phase 5 workflow regenerated with RSSI, RSRP and RSRQ in
%   the feature schema. Those three were overlooked when the windowed feature
%   block was written and could not be recovered from the saved logs, because
%   SINR is a ratio and no absolute power figure was ever captured. The fix
%   needs a PHY-layer tap and a full re-simulation of every seed, which is
%   what this configuration enumerates.
%
%   The scenario fixes the topology. The seed fixes UE placement, aerial UE
%   count, mobility, traffic jitter, LOS and shadow-fading draws, channel
%   seeds and handover measurement error, so the same seed and scenario give
%   an identical run.

    cfg = struct();

    cfg.batch = struct();

    % Development and honest hold-out in one sweep: 1 to 45 training, 46 to 60
    % held out, 20/20/20 across the three scenarios.
    cfg.batch.seedRange = 1:60;

    cfg.batch.scenarioCycle = ["UMa", "RMa", "UMi"];

    % Keyed to the seed value, not to position in the range, so the mapping
    % survives reordering, trimming, splitting across batches and other
    % machines. Resolved by phase5b_ScenarioFor.
    cfg.batch.scenarioFrom = "seed";

    % Phase 5b regenerates every run, so no seed is pinned to a scenario it
    % was historically written under. Phase 5 pinned seeds 37 to 45 because
    % nine finished runs had to keep the identity they were written with;
    % nothing here is inherited, so seeds 1 to 60 are 20/20/20 under the
    % pure seed rule and seed-matched to the adversarial machine throughout.
    cfg.batch.scenarioOverride = [];

    cfg.batch.maxRuns = Inf;

    % One run per worker, no queue: a pool smaller than the seed range
    % shortens the batch rather than deferring the remainder. 60 concurrent
    % simulations is the memory ceiling to watch; the 6 August Phase 5 crash
    % was an out-of-memory kill at twenty-four.
    cfg.batch.numWorkers = [60];

    % Manifest filename label, "" for a yyyymmdd_HHMMSS stamp.
    cfg.batch.tag = "";

    % Output directory, "" resolves to <Phase 7 copy>/data.
    cfg.batch.dataDir = "";

    cfg.batch.skipExisting = true;
    cfg.batch.continueOnError = true;
    cfg.batch.verboseWorkers = false;

    % Prior only; phase5b_CostModel prefers measurements in
    % data/costmodel_measured.csv when they exist. 33.6 s per simulated second
    % per gNB per UE is the Phase 5 six-worker figure and only matters on a
    % machine with no measurements yet.
    cfg.batch.costModel = struct('sPerSimSecPerGNBPerUE', 79.8);

    cfg.batch.poolRetries       = 2;     % extra attempts per size and range
    cfg.batch.poolRetryWait_s   = 15;    % pause between attempts
    cfg.batch.allowFewerWorkers = true;  % halve and retry rather than abort

    % [] keeps the default, 0 asks for ephemeral ports, a pair is an explicit
    % range. Blocked ranges on Windows:
    %   netsh int ipv4 show excludedportrange protocol=tcp
    cfg.batch.poolPortRanges = {[], 0, [40000 41000], [21000 22000]};

    cfg.progress = struct();
    % false suppresses the live display; the per-run record prints either way.
    cfg.progress.enable        = true;
    % One coloured bar per run in a single window, with the aggregate on a
    % header line. Above maxBars it falls back to one aggregate waitbar.
    cfg.progress.perRunBars    = true;
    cfg.progress.maxBars       = 60;
    cfg.progress.useWaitbar    = true;   % fallback bar; false forces text
    % Also sets how often each run's ETA is re-estimated.
    cfg.progress.updatesPerRun = 100;
    % Weight on the newest rate sample: higher tracks change but is noisier.
    cfg.progress.rateAlpha     = 0.35;
    % Seconds between redraws. Every property set on the window is a message
    % into MATLAB's Chromium process, which is what ran out of memory on
    % 6 August; a run reports once per per cent, so 5 s costs nothing.
    cfg.progress.minRedraw_s   = 5;
    % Plain-text status board, rewritten on every redraw. "" disables it. The
    % only readout that does not depend on the desktop surviving, and the only
    % way to watch a batch started with matlab -batch.
    cfg.progress.statusFile    = "batch_status.txt";

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
    % place and warns. true is worth setting for a long unattended batch.
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
    % earlier CSVs. Held at the Phase 5 values, so a Phase 5b row is a Phase 5
    % row with fifteen columns appended.
    cfg.window = struct();
    cfg.window.simulationTime = 60.5;   % s; must exceed windowLen
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
    cfg.replay.save = true;
    cfg.replay.format = "-v7.3";        % needed above the 2 GB v7 limit
    cfg.replay.includeNodes = true;     % false shrinks the file but the
                                        % replay then draws no node marks
    cfg.replay.cullTime = [];           % s; [] culls the settle span only
    % Seeds that write a replay bundle. The bundles are by far the largest
    % artefact a run produces and sixty of them would dominate the output for
    % no analytical gain, so only the first three are kept: enough to inspect
    % the mechanism and to check the renderer against the live LOS state.
    % [] restores one bundle per run.
    cfg.replay.saveSeeds = [1 2 3];

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
