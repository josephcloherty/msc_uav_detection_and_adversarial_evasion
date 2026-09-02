function cfg = phase5_Config()
% returns the complete parameter set for the Phase 5 batch pipeline. nothing else
% in Phase 5 holds a tunable value, so change the dataset by changing this file.

    cfg = struct();

    %% batch control
    cfg.batch = struct();

    % seeds to run on this machine, one per worker
    cfg.batch.seedRange = 46:57;

    % scenario cycled one per run, chosen from the seed value
    cfg.batch.scenarioCycle = ["UMa", "RMa", "UMi"];

    % how a run's scenario is decided: "seed" or the old "position" rule
    cfg.batch.scenarioFrom = "seed";

    % seeds generated under the old positional rule, pinned to the scenario
    % they were actually run with so their files are still recognised.
    cfg.batch.scenarioOverride = struct( ...
        'seed',     37:45, ...
        'scenario', ["RMa" "UMi" "UMa" "RMa" "UMi" "UMa" "RMa" "UMi" "UMa"]);

    % hard cap on runs executed
    cfg.batch.maxRuns = Inf;

    % pool size, and therefore the number of runs per batch. one worker per
    % core: memory is the binding constraint.
    cfg.batch.numWorkers = [12];

    % manifest filename label; "" uses a timestamp
    cfg.batch.tag = "";

    % output directory; "" resolves to Phase 5/data
    cfg.batch.dataDir = "";

    % skip a run whose CSV already exists
    cfg.batch.skipExisting = true;

    % record a failed run and carry on
    cfg.batch.continueOnError = true;

    % per-run console chatter from the workers
    cfg.batch.verboseWorkers = false;

    % wall-time cost prior, seconds per simulated second per gNB per UE.
    % measured values in data/costmodel_measured.csv take precedence.
    cfg.batch.costModel = struct('sPerSimSecPerGNBPerUE', 33.6);

    % pool startup fallbacks, for when the client cannot bind its port
    cfg.batch.poolRetries       = 2;     % extra attempts
    cfg.batch.poolRetryWait_s   = 15;    % seconds between attempts
    % a smaller pool means a shorter batch, not a queue
    cfg.batch.allowFewerWorkers = true;  % halve and retry

    % client port ranges to try, in order
    cfg.batch.poolPortRanges = {[], 0, [40000 41000], [21000 22000]};

    %% progress reporting
    cfg.progress = struct();
    cfg.progress.enable        = true;
    % one bar per run, falling back to a single aggregate bar
    cfg.progress.perRunBars    = true;
    cfg.progress.maxBars       = 40;
    cfg.progress.useWaitbar    = true;  % fallback bar
    % progress messages per run; 100 gives one per cent resolution
    cfg.progress.updatesPerRun = 100;
    % weight on the newest sample in each run's rate estimate
    cfg.progress.rateAlpha     = 0.35;

    % seconds between redraws, kept high because each one is a message to
    % the process hosting the desktop.
    cfg.progress.minRedraw_s   = 5;

    % plain-text status board, the readout that survives losing the desktop
    cfg.progress.statusFile    = "batch_status.txt";

    %% radio, kept at the earlier phase values so the CSVs stay comparable
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

    % fixed terrestrial background, so only the aerial signature varies
    cfg.population.numTerrestrialUE = 8;

    % aerial count randomised per run: a group with probability
    % pMultiAerial, otherwise a lone UE.
    cfg.population.pMultiAerial = 0.5;

    % aerial UEs in a single-aerial run
    cfg.population.singleAerialCount = 1;

    % inclusive group size for a multi-aerial run, drawn uniformly
    cfg.population.aerialSwarmSizeRange = [2 6];

    %% mobility
    cfg.mobility = struct();
    cfg.mobility.enable = true;

    % speed ranges (m/s) for the random-waypoint model
    cfg.mobility.aerialSpeedRange      = [15 30];
    cfg.mobility.terrestrialSpeedRange = [1 5];

    % bounds convention: "centre" is [xCentre yCentre width height]
    cfg.mobility.boundsConvention = "centre";

    %% traffic
    % class profiles carried over from Phase 4. aerial is uplink-heavy video
    % plus a command and control downlink; terrestrial is bursty browsing.
    %                                kbps   on(s)  off(s)  pkt(B)
    cfg.traffic = struct();
    cfg.traffic.aerial.ul      = trafficSpec(4000,  Inf,  0,    1250);
    cfg.traffic.aerial.dl      = trafficSpec( 100,  Inf,  0,    1250);
    cfg.traffic.terrestrial.dl = trafficSpec(2000,  1,    2,    1500);
    cfg.traffic.terrestrial.ul = trafficSpec( 200,  0.5,  2.5,   500);

    % per-UE jitter, drawn once per run and then frozen
    cfg.traffic.rateJitterFrac   = 0.15;
    cfg.traffic.timingJitterFrac = 0.20;   % finite on/off times

    %% measurement
    cfg.measurement = struct();
    cfg.measurement.visThreshold = 0;    % dB, visibility threshold

    % SRS RNTI offset, an empirical constant verified in flight each run
    cfg.measurement.rntiOffset = -2;

    % verify the offset at the settle time
    cfg.measurement.verifyRNTI = true;

    % on a mismatch: false aborts naming the correct offset, true corrects
    % the managers in place and warns.
    cfg.measurement.autoCorrectRNTI = false;

    % print the per-UE RNTI map before each run
    cfg.measurement.printRNTIMap = true;

    %% handover and mobility chain
    % TR 36.777 Table A.2.1-1 baseline values, restated so the chain is
    % adjustable from here. the defaults reproduce the class defaults.
    cfg.handover = struct();
    cfg.handover.useTr36777Mobility = true;   % false uses A3
    cfg.handover.a3Offset      = 2;      % dB
    cfg.handover.ttt           = 0.160;  % seconds
    cfg.handover.l1WindowSec   = 0.200;  % seconds
    cfg.handover.l3K           = 1;      % filter coefficient
    cfg.handover.hoPrepDelay   = 0.050;  % seconds
    cfg.handover.hoExecDelay   = 0.040;  % seconds
    cfg.handover.measErrStd    = 1.22;   % dB, decision chain
    cfg.handover.mtsPingPong   = 1;      % minimum time of stay
    cfg.handover.hysteresis    = 1;      % dB, legacy A3
    cfg.handover.sinrThreshold = 20;     % dB, A5 threshold
    % scanPeriod and scanStartTime are absent on purpose: the manager
    % schedules its scan in its constructor, so setting them here is ignored.
    %% windowing; changing these makes rows incomparable with earlier CSVs
    cfg.window = struct();
    cfg.window.simulationTime = 60.5;   % seconds
    cfg.window.windowLen      = 10;     % seconds
    cfg.window.windowStride   = 1;      % seconds
    cfg.window.settleTime     = 0.5;    % seconds, discarded

    %% channel
    cfg.channel = struct();
    cfg.channel.enableShadowFading = true;

    % dynamic LOS state; false restores the frozen Phase 4 behaviour
    cfg.channel.dynamicLOS = true;

    % correlation distance (m) for the LOS field; empty uses the standard value
    cfg.channel.losCorrelationDistance_m = [];

    %% replay files
    cfg.replay = struct();
    cfg.replay.save = true;             % one replay per run
    cfg.replay.format = "-v7.3";        % above the 2 GB limit
    cfg.replay.includeNodes = true;     % node objects in the bundle
    cfg.replay.cullTime = [];           % [] culls the settle span

    %% SRS capacity
    % every UE holds a link to every gNB, so the per-gNB count is the total
    % and the default configuration caps it at 16.
    cfg.srs = struct();
    cfg.srs.maxUEsPerGNB = 16;
    % SRS periodicity override in slots; [] leaves the toolbox default
    cfg.srs.periodicitySlots = [];

    %% scenarios: topology and TR 36.777 parameters, not seed dependent
    cfg.scenarios = struct();

    % UMa, the primary deployment scenario
    s = struct();
    s.zBoundary = 22.5;                 % UMa-AV floor
    s.avgBuildingHeight = 20;           % m, rooftop reflection
    % Table B.1.1-2, UMa-AV
    s.av.los  = struct('ASA',0.5,'ASD',0.5,'ZSA',0.1,'ZSD',0.1, ...
                       'K_dB',20,'DS_s',10e-9);
    s.av.nlos = struct('ASA',1,  'ASD',1,  'ZSA',0.3,'ZSD',0.3, ...
                       'K_dB',10,'DS_s',30e-9);
    s.aerialChannelBuilder = "";        % CDL-D based
    s.topology = struct('numGNB', 5, ...            % centre plus a ring
                        'siteRadius_m', 750, ...    % 1500 m across
                        'gnbHeight_m', 25, ...      % Table B-1 Note 1
                        'ueAreaSpan_m', 2200, ...   % square UE region
                        'originOffset_m', [0 0]);
    s.terrestrialAlt_m  = 1.5;
    s.aerialAltRange_m  = [40 200];     % above the floor
    cfg.scenarios.UMa = s;

    % RMa, the second fork
    s = struct();
    s.zBoundary = 10;                   % RMa-AV floor
    s.avgBuildingHeight = NaN;          % ground reflection
    % Table B.1.1-1, RMa-AV
    s.av.los  = struct('ASA',0.2,'ASD',0.2,'ZSA',0.1,'ZSD',0.1, ...
                       'K_dB',20,'DS_s',10e-9);
    s.av.nlos = struct('ASA',0.5,'ASD',0.5,'ZSA',0.2,'ZSD',0.2, ...
                       'K_dB',10,'DS_s',30e-9);
    s.aerialChannelBuilder = "";
    s.topology = struct('numGNB', 5, ...
                        'siteRadius_m', 1500, ...   % 3000 m across
                        'gnbHeight_m', 25, ...
                        'ueAreaSpan_m', 3600, ...
                        'originOffset_m', [0 0]);
    s.terrestrialAlt_m  = 1.5;
    s.aerialAltRange_m  = [40 200];
    cfg.scenarios.RMa = s;

    % UMi, the third fork
    s = struct();
    s.zBoundary = 22.5;
    s.avgBuildingHeight = NaN;          % unused here
    s.av = [];                          % not CDL-D based
    s.aerialChannelBuilder = "buildUMiAVChannel";
    s.topology = struct('numGNB', 5, ...
                        'siteRadius_m', 400, ...
                        'gnbHeight_m', 10, ...      % street-level site
                        'ueAreaSpan_m', 1200, ...
                        'originOffset_m', [0 0]);
    s.terrestrialAlt_m  = 1.5;
    s.aerialAltRange_m  = [40 150];
    cfg.scenarios.UMi = s;
end

function s = trafficSpec(kbps, on, off, pkt)
% returns one networkTrafficOnOff specification.
    s = struct('dataRate_kbps', kbps, 'onTime_s', on, ...
               'offTime_s', off, 'packetSize_B', pkt);
end
