function cfg = phase7_Config()
%phase7_Config Every tunable value for the Phase 7 pipeline, in one place.
%
%   CFG = phase7_Config() returns the full parameter set. phase7_RunBatch
%   reads it, phase7_ScenarioGen expands it into one run config per seed, and
%   phase7_Pipeline consumes that. To change the dataset, change this file.
%
%   The scenario fixes the topology (gNB count, positions, heights, carrier,
%   site radius, UE region). The seed drives everything else: UE placement,
%   aerial UE count, mobility, traffic jitter, LOS and shadow-fading draws,
%   channel seeds and handover measurement error.
%
%   Same seed and scenario gives an identical run, and seeds are plain
%   integers, so a seed range splits across machines without coordination.

    cfg = struct();

    %% batch control
    cfg.batch = struct();

    % Seeds to run on this machine; use a disjoint range on each machine.
    cfg.batch.seedRange = 13:36;

    % Scenario cycled one per run; changing the length of this list changes
    % which scenario a given seed index maps to.
    cfg.batch.scenarioCycle = ["UMa", "RMa", "UMi"];

    % Hard cap on runs actually executed, Inf for all seeds.
    cfg.batch.maxRuns = Inf;

    % Pool size, [] for the profile default; each worker holds one full
    % simulation, so memory scales with this.
    cfg.batch.numWorkers = [12];

    % Manifest filename label, "" for a yyyymmdd_HHMMSS stamp.
    cfg.batch.tag = "";

    % Output directory, "" resolves to <Phase 7>/data.
    cfg.batch.dataDir = "";

    % Skip a run whose feature CSV already exists, so a batch is resumable.
    cfg.batch.skipExisting = true;

    % Record a failed run in the manifest and carry on.
    cfg.batch.continueOnError = true;

    % Per-run console output from the workers; the client reports progress
    % either way.
    cfg.batch.verboseWorkers = false;

    % Seconds of wall time per (simulated second x gNB x UE), used only as a
    % prior until real runs exist.
    % phase7_CostModel keeps the measurements in data/costmodel_measured.csv
    % and every estimate prefers those to this number.
    cfg.batch.costModel = struct('sPerSimSecPerGNBPerUE', 33.6);

    % Pool startup can fail on the client's listening port for reasons
    % outside this project, so the runner retries before giving up.
    cfg.batch.poolRetries       = 2;     % extra attempts per size and range
    cfg.batch.poolRetryWait_s   = 15;    % pause between attempts
    cfg.batch.allowFewerWorkers = true;  % halve and retry rather than abort

    % Port ranges to try via pctconfig: [] keeps the default, 0 asks for
    % ephemeral ports, a pair is an explicit range.
    % To list blocked ranges on Windows:
    %   netsh int ipv4 show excludedportrange protocol=tcp
    cfg.batch.poolPortRanges = {[], 0, [40000 41000], [21000 22000]};

    %% progress reporting (command line only)
    % The client prints a throttled aggregate line, one line per completed
    % run, and a DONE block at the end.
    % enable false drops the aggregate lines but keeps the rest.
    cfg.progress = struct();
    cfg.progress.enable        = true;
    % Progress messages per run, which is also how often each run's ETA is
    % re-estimated; a high value on a large pool just costs client time.
    cfg.progress.updatesPerRun = 100;
    % Weight on the newest rate sample: higher tracks a changing cost more
    % closely but is noisier.
    cfg.progress.rateAlpha     = 0.35;
    % Minimum gap between aggregate lines, so a long batch does not flood the
    % command window.
    cfg.progress.minPrint_s    = 5;

    %% radio
    % Shared by every scenario, at the Phase 2-4 values so the dataset stays
    % comparable with the earlier CSVs.
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

    %% UE population
    cfg.population = struct();

    % Fixed background population, so the aerial side is what varies.
    cfg.population.numTerrestrialUE = 8;

    % Chance that a run holds a group of aerial UEs rather than one.
    cfg.population.pMultiAerial = 0.5;

    % Number of aerial UEs in a single-aerial run.
    cfg.population.singleAerialCount = 1;

    % Inclusive [min max] group size for a multi-aerial run, drawn uniformly.
    % Every aerial UE gets its own placement, mobility and traffic draws.
    cfg.population.aerialSwarmSizeRange = [2 6];

    % With the defaults above the aerial fraction runs 11% to 43%.

    %% mobility
    cfg.mobility = struct();
    cfg.mobility.enable = true;

    % Speed ranges (m/s) for the toolbox random-waypoint model.
    cfg.mobility.aerialSpeedRange      = [15 30];
    cfg.mobility.terrestrialSpeedRange = [1 5];

    % How to read the Bounds vector addMobility takes: "centre" is
    % [xCentre yCentre width height], "corner" is [xMin yMin width height].
    % Leave it on "centre" unless the toolbox changes.
    cfg.mobility.boundsConvention = "centre";

    %% traffic
    % Class profiles carried over from Phase 4: aerial is uplink-heavy steady
    % video with TR 36.777 command and control on the downlink, terrestrial
    % is downlink-heavy bursty browsing.
    %                                kbps   on(s)  off(s)  pkt(B)
    cfg.traffic = struct();
    cfg.traffic.aerial.ul      = trafficSpec(4000,  Inf,  0,    1250);
    cfg.traffic.aerial.dl      = trafficSpec( 100,  Inf,  0,    1250);
    cfg.traffic.terrestrial.dl = trafficSpec(2000,  1,    2,    1500);
    cfg.traffic.terrestrial.ul = trafficSpec( 200,  0.5,  2.5,   500);

    % Per-UE jitter, drawn once per run and then frozen, so the sources stay
    % deterministic.
    % 0.15 scales each rate by a factor from [0.85 1.15]; use 0 for identical
    % sources within a class.
    cfg.traffic.rateJitterFrac   = 0.15;
    cfg.traffic.timingJitterFrac = 0.20;   % applies to finite On/Off times

    %% measurement
    cfg.measurement = struct();
    cfg.measurement.visThreshold = 0;    % dB; gNB counts as visible above this

    % SRS events identify a UE as UE.ID + rntiOffset, and the managers filter
    % on that.
    % It is empirical, and a wrong value fails silently with every SINR
    % column NaN, so every run verifies it in flight.
    % Not to be confused with the scheduler RNTI, read from the gNB tables.
    cfg.measurement.rntiOffset = -2;

    % Check the offset against real SRS events at the settle time, inside the
    % span the extraction throws away anyway.
    cfg.measurement.verifyRNTI = true;

    % On a mismatch, false aborts and names the right offset while true fixes
    % the managers in place and warns.
    % Worth setting true for long unattended batches, since the correction
    % lands inside the settle window either way.
    cfg.measurement.autoCorrectRNTI = false;

    % Print the per-UE RNTI map before each run.
    cfg.measurement.printRNTIMap = true;

    %% handover / mobility chain
    % TR 36.777 Table A.2.1-1 baselines, applied to each manager after
    % construction and matching the class defaults exactly.
    % Changing any of them changes the handover features, so rows generated
    % under different values are not comparable.
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
    % Do not add scanPeriod or scanStartTime here, because handoverManager
    % schedules its scan in the constructor and would ignore them.

    %% windowing
    % These define the features, so changing them makes rows incomparable
    % with every earlier CSV.
    cfg.window = struct();
    cfg.window.simulationTime = 60.5;   % s; must exceed windowLen
    cfg.window.windowLen      = 10;     % s, per-UE sliding window
    cfg.window.windowStride   = 1;      % s
    cfg.window.settleTime     = 0.5;    % s, discarded attach/handover burst

    %% channel
    cfg.channel = struct();
    cfg.channel.enableShadowFading = true;

    % true evaluates LOS/NLOS per packet from a spatially consistent random
    % field (TR 38.901 clause 7.6.3.1), so a moving UE changes state.
    % false freezes the state at the initial positions, which is Phase 4
    % behaviour and only useful for regenerating a comparison dataset.
    cfg.channel.dynamicLOS = true;

    % Correlation distance (m) for the LOS field; empty uses the TR 38.901
    % Table 7.6.3.1-2 value (50 m UMa and UMi, 60 m RMa).
    % Only set a number for a sensitivity study, and log it.
    cfg.channel.losCorrelationDistance_m = [];

    %% replay files
    cfg.replay = struct();
    cfg.replay.save = true;             % one replay .mat per run
    cfg.replay.format = "-v7.3";        % needed above the 2 GB v7 limit
    cfg.replay.includeNodes = true;     % gNB/UE objects in the bundle; false
                                        % shrinks the file but the replay
                                        % then draws no node marks
    cfg.replay.cullTime = [];           % s; [] culls the settle span only

    %% SRS capacity
    % Every UE holds an uplink to every gNB so all cells receive its SRS,
    % which makes the per-gNB UE count equal the total UE count.
    % The default SRS configuration caps that at 16, and the generator
    % asserts the limit before a run starts.
    cfg.srs = struct();
    cfg.srs.maxUEsPerGNB = 16;
    % Periodicity override in slots, [] for the toolbox default.
    % This is the documented route past the 16-UE limit, so log it when used.
    cfg.srs.periodicitySlots = [];

    %% scenarios
    % Topology and TR 36.777 parameters, none of it seed dependent.
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

%% ------------------------------------------------------------------------
function s = trafficSpec(kbps, on, off, pkt)
%trafficSpec One networkTrafficOnOff specification.
    s = struct('dataRate_kbps', kbps, 'onTime_s', on, ...
               'offTime_s', off, 'packetSize_B', pkt);
end
