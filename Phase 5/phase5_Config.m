function cfg = phase5_Config()
%phase5_Config Single configuration point for the Phase 5 dataset pipeline (D5.1).
%
%   CFG = phase5_Config() returns the complete parameter set for the
%   parallelised multi-cell scenario generator and batch runner. Nothing
%   else in Phase 5 holds a tunable value: phase5_RunBatch reads this
%   file, phase5_ScenarioGen expands it into one concrete run
%   configuration per seed, and phase5_Pipeline consumes that. To change
%   the dataset, change this file only.
%
%   WHAT VARIES WITH THE SEED, AND WHAT DOES NOT
%   --------------------------------------------
%   The network topology is a property of the SCENARIO, not of the run.
%   For a given scenario name the gNB count, site radius, gNB height and
%   carrier are fixed, so every replicate of that scenario observes the
%   same deployment. The seed drives only the things a real
%   operator would see change between observation periods:
%
%     - initial UE placement (terrestrial and aerial, in x, y and z)
%     - how many aerial UEs are present in the run
%     - mobility (speeds are drawn per UE inside the toolbox mobility
%       model from the run's global stream, which is seeded from cfg.seed)
%     - per-UE traffic rate and on/off timing jitter around the class
%       profile
%     - per-link LOS draws, shadow fading draws and channel seeds
%     - handover measurement-error draws
%
%   Two runs with the same seed and scenario are therefore identical, and
%   two runs with different seeds are independent replicates of the same
%   deployment. Seeds are plain integers, so a seed range can be split
%   across machines with no coordination: machine A runs 1:50, machine B
%   runs 51:100, and the union is one dataset with no duplicated or
%   missing runs.
%
%   RUN ENUMERATION
%   ---------------
%   Run i takes seed cfg.batch.seedRange(i) and scenario
%   cfg.batch.scenarioCycle(mod(i-1, numel(cycle))+1), so the scenarios
%   are cycled one per run. numel(cfg.batch.seedRange) is therefore the
%   number of scenario replicates the batch will generate.
%
%   OUTPUTS PER RUN (all into cfg.batch.dataDir)
%   --------------------------------------------
%     features_<scenario>_seed<seed>.csv   labelled windowed feature rows
%     replay_<scenario>_seed<seed>.mat     replay bundle, reopened with
%                                          replayScenario(path) or
%                                          phase5_ReplayRun(scenario, seed)
%   and one manifest_<tag>.csv for the batch recording every generation
%   parameter needed to reproduce it (D5.5 groundwork).

    cfg = struct();

    %% ==================================================================
    %  BATCH CONTROL
    %  ==================================================================
    cfg.batch = struct();

    % Seeds to run on THIS machine. Any numeric vector; 1:6 here,
    % 7:12 on the next machine, and so on.
    %
    % Sized deliberately small for the first batch. At the measured cost
    % (see cfg.batch.costModel) a run is several hours, so six runs is
    % two replicates per scenario and roughly three thousand rows: enough
    % to look at class separation in D5.4 and size the real batch from
    % what it shows. phase5_DryRun projects the wall time before you
    % commit to it.
    cfg.batch.seedRange = 1:12;

    % Scenario cycled one per run. Any subset/order of the names defined
    % in cfg.scenarios below. "UMa" is the primary deployment scenario,
    % "RMa" the required second fork, "UMi" the optional third, included
    % here at equal weight so all three are represented in the dataset.
    % Changing the length of this list changes which scenario a given
    % seed index maps to, so a seed range run under a different cycle
    % produces a different set of runs (existing files are not
    % overwritten: the run identity is the scenario and seed pair).
    cfg.batch.scenarioCycle = ["UMa", "RMa", "UMi"];

    % Hard cap on the number of runs actually executed (Inf = all seeds).
    % Useful for a short smoke batch without editing seedRange.
    cfg.batch.maxRuns = Inf;

    % Parallel pool size. [] uses the default profile's worker count.
    % Each worker holds one full simulation, so memory scales with this.
    cfg.batch.numWorkers = [12];

    % Label used in the manifest filename. "" uses a yyyymmdd_HHMMSS stamp.
    cfg.batch.tag = "";

    % Output directory. "" resolves to <Phase 5>/data.
    cfg.batch.dataDir = "";

    % Skip a run whose feature CSV already exists. Makes a batch
    % resumable after an interruption and safe to re-launch.
    cfg.batch.skipExisting = true;

    % Record a failed run in the manifest and carry on, rather than
    % aborting the whole batch.
    cfg.batch.continueOnError = true;

    % Per-run console chatter from the workers. Progress is reported by
    % the client regardless.
    cfg.batch.verboseWorkers = false;

    % Wall-time cost model. The constant is seconds of wall time per
    % (simulated second x gNB x UE). Cost is dominated by per-packet
    % channel filtering across the UE-to-gNB links and by every UE's SRS
    % being received at every gNB, both of which scale with that product.
    %
    % This value is only the PRIOR, used until real runs exist. It came
    % from the 21 July smoke runs, 1881 s for 6 s at 7 gNB and 3 UE, where
    % fixed per-run overhead is a large share of a six second run, and the
    % first full batch cost 33.6 rather than 14.9. phase5_CostModel keeps
    % the measurements from every finished run in
    % data/costmodel_measured.csv and both the dry run projection and the
    % live ETA use those in preference to this number, per pool size,
    % since cost per run rises with contention. The value below is
    % therefore left at the measured figure for the six-worker batch and
    % only matters on a machine with no measurements yet.
    cfg.batch.costModel = struct('sPerSimSecPerGNBPerUE', 33.6);

    % Parallel pool startup. The client binds a listening port for the
    % interactive pool, by default from 27370 up, and that bind fails for
    % reasons outside this project: a Windows reserved port block from
    % Hyper-V, WSL or Docker covering the range, a firewall blocking
    % loopback, workers orphaned by a killed session still holding the port,
    % stale cluster job metadata, or a machine too loaded to finish every
    % handshake in time. Rather than lose a night to it, the runner tries
    % each port range below, then retries, then steps the worker count down.
    cfg.batch.poolRetries       = 2;     % extra attempts per size and range
    cfg.batch.poolRetryWait_s   = 15;    % pause between attempts
    cfg.batch.allowFewerWorkers = true;  % halve and retry rather than abort

    % Client listening port ranges to try, in order, via pctconfig. [] keeps
    % MATLAB's default 27370-28370; 0 asks for ephemeral ports, which the OS
    % picks from what is genuinely free and so cannot collide with a fixed
    % reservation; a two-element vector is an explicit range. Diagnose a
    % blocked range with, in a command prompt:
    %   netsh int ipv4 show excludedportrange protocol=tcp
    cfg.batch.poolPortRanges = {[], 0, [40000 41000], [21000 22000]};

    %% ==================================================================
    %  PROGRESS REPORTING
    %  ==================================================================
    % The client shows one aggregated readout for the whole batch, in the
    % same terms the Phase 3 and Phase 4 single-run reporter used:
    % simulated-time progress, wall time and estimated time remaining.
    % Workers report their own simulated-time fraction periodically, so
    % the bar moves continuously rather than only when a run finishes.
    % enable false suppresses the live display entirely; the
    % one-line-per-completed-run record is printed either way.
    cfg.progress = struct();
    cfg.progress.enable        = true;
    % perRunBars true draws one horizontal bar per run in a single
    % window, coloured by state, with the aggregate on a header line, so
    % it is visible which runs are in flight and how far each has got.
    % False, or a batch larger than maxBars where one bar per run would
    % be unreadable, falls back to a single aggregate waitbar.
    cfg.progress.perRunBars    = true;
    cfg.progress.maxBars       = 40;
    cfg.progress.useWaitbar    = true;  % fallback bar; false forces text
    % Progress messages per run. Each one is a message from a worker to
    % the client, so a high value on a large pool costs client time for
    % no extra information. 100 gives one per cent resolution, which at
    % these run lengths is a report every twenty minutes or so per run and
    % is also the rate at which each run's ETA is re-estimated.
    cfg.progress.updatesPerRun = 100;
    % Weight on the newest sample in each run's rate estimate. Higher
    % follows a run whose cost is changing more closely and is noisier;
    % lower is smoother and slower to notice a slowdown.
    cfg.progress.rateAlpha     = 0.35;
    cfg.progress.minRedraw_s   = 0.5;   % throttle between redraws

    %% ==================================================================
    %  RADIO (shared by every scenario, kept at the Phase 2-4 values so
    %  the Phase 5 dataset stays comparable with the earlier CSVs)
    %  ==================================================================
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

    %% ==================================================================
    %  UE POPULATION
    %  ==================================================================
    cfg.population = struct();

    % Terrestrial UEs are a fixed background population: the same number
    % in every run, so the aerial signature is what varies.
    cfg.population.numTerrestrialUE = 8;

    % Aerial count is randomised per run. With probability pMultiAerial
    % the run contains a group of aerial UEs, otherwise a lone one. The
    % default 0.5 targets a roughly even split of single-aerial and
    % multi-aerial runs across the dataset.
    cfg.population.pMultiAerial = 0.5;

    % Number of aerial UEs in a single-aerial run.
    cfg.population.singleAerialCount = 1;

    % Inclusive [min max] group size for a multi-aerial run, drawn
    % uniformly. Each aerial UE gets independent placement, mobility and
    % traffic draws; there is no leader/follower differentiation (see the
    % deviations log entry on swarm C2 modelling).
    cfg.population.aerialSwarmSizeRange = [2 6];

    % Resulting aerial fraction with the defaults above: 1/9 to 6/14,
    % i.e. 11% to 43%, straddling the ~20% target of D5.1.

    %% ==================================================================
    %  MOBILITY
    %  ==================================================================
    cfg.mobility = struct();
    cfg.mobility.enable = true;

    % Speed ranges (m/s) handed to the toolbox random-waypoint model.
    cfg.mobility.aerialSpeedRange      = [15 30];
    cfg.mobility.terrestrialSpeedRange = [1 5];

    % Interpretation of the four-element Bounds vector passed to
    % addMobility. "centre" is [xCentre yCentre width height] and is the
    % convention verified against the recorded Phase 3 trajectories;
    % "corner" is [xMin yMin width height]. Kept configurable so a
    % toolbox behaviour change can be absorbed here rather than in code.
    cfg.mobility.boundsConvention = "centre";

    %% ==================================================================
    %  TRAFFIC
    %  ==================================================================
    % Class profiles carried over unchanged from Phase 4 (sources and the
    % confound discussion are in the Phase 4 deviations log). Aerial:
    % uplink-heavy steady video plus the TR 36.777 command and control
    % model on the downlink. Terrestrial: downlink-heavy bursty browsing.
    %                                kbps   on(s)  off(s)  pkt(B)
    cfg.traffic = struct();
    cfg.traffic.aerial.ul      = trafficSpec(4000,  Inf,  0,    1250);
    cfg.traffic.aerial.dl      = trafficSpec( 100,  Inf,  0,    1250);
    cfg.traffic.terrestrial.dl = trafficSpec(2000,  1,    2,    1500);
    cfg.traffic.terrestrial.ul = trafficSpec( 200,  0.5,  2.5,   500);

    % Per-UE jitter, drawn once per run from the seeded scenario stream
    % and then frozen as fixed scalars, so every traffic source stays
    % deterministic and the run remains byte-reproducible. A value of
    % 0.15 means each rate is scaled by a factor drawn uniformly from
    % [0.85 1.15]. Set to 0 for the Phase 4 behaviour (identical sources
    % within a class).
    cfg.traffic.rateJitterFrac   = 0.15;
    cfg.traffic.timingJitterFrac = 0.20;   % applies to finite On/Off times

    %% ==================================================================
    %  MEASUREMENT
    %  ==================================================================
    cfg.measurement = struct();
    cfg.measurement.visThreshold = 0;    % dB; gNB counts as visible above this

    % SRS RNTI offset. SRS reception events identify a UE as
    % UE.ID + rntiOffset, and the handover managers filter on that. This
    % is an empirical constant (SLS library ID convention): -2 has held
    % at three, five and seven gNBs, but nothing in the toolbox enforces
    % it and a wrong value fails SILENTLY, with the managers ingesting
    % nothing and the run completing after hours with every SINR column
    % NaN. It is therefore verified in flight on every run rather than
    % trusted. The scheduler RNTI is a different quantity entirely and is
    % never calibrated: it is read from the gNB connection tables.
    cfg.measurement.rntiOffset = -2;

    % Verify the offset against observed SRS events at the settle time,
    % inside the span the extraction discards. Leave this on.
    cfg.measurement.verifyRNTI = true;

    % On a mismatch: false aborts the run naming the correct offset,
    % true corrects the managers in place and warns. False is the safer
    % default and matches the rest of the pipeline preferring a loud
    % failure to a silent repair; true is worth setting for long
    % unattended batches, where losing a thirteen hour run to a
    % recalibratable constant is the worse outcome. The correction lands
    % inside the settle window either way, so no dataset row is computed
    % from measurements taken under the wrong identifier.
    cfg.measurement.autoCorrectRNTI = false;

    % Print the per-UE RNTI map (node ID, class, anchor gNB, scheduler
    % RNTI, SRS RNTI) before each run.
    cfg.measurement.printRNTIMap = true;

    %% ==================================================================
    %  HANDOVER / MOBILITY CHAIN
    %  ==================================================================
    % TR 36.777 Table A.2.1-1 baseline values, restated here so the whole
    % measurement chain is adjustable from the configuration rather than
    % by editing handoverManager. Every field is applied to each manager
    % after construction; the defaults below reproduce the class defaults
    % exactly, so leaving this block alone gives Phase 3 and Phase 4
    % behaviour. Changing any of them changes the handover features, so
    % rows generated under different values are not comparable.
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
    % scanPeriod and scanStartTime are deliberately absent: handoverManager
    % schedules its periodic scan inside its constructor, so a value set
    % afterwards would be accepted and then ignored. The pipeline rejects
    % them explicitly rather than letting that pass silently.

    %% ==================================================================
    %  WINDOWING (feature definition: changing these makes rows
    %  incomparable with every earlier CSV)
    %  ==================================================================
    cfg.window = struct();
    cfg.window.simulationTime = 60.5;   % s; must exceed windowLen
    cfg.window.windowLen      = 10;     % s, per-UE sliding window
    cfg.window.windowStride   = 1;      % s
    cfg.window.settleTime     = 0.5;    % s, discarded attach/handover burst

    %% ==================================================================
    %  CHANNEL
    %  ==================================================================
    cfg.channel = struct();
    cfg.channel.enableShadowFading = true;

    % Dynamic LOS state (Phase 5). true evaluates the LOS/NLOS state per
    % packet from a spatially-consistent random field (TR 38.901 clause
    % 7.6.3.1), so a moving UE changes state as its geometry changes.
    % false restores the Phase 4 behaviour, where the state was drawn once
    % from the INITIAL positions and frozen for the whole run - kept only
    % so a Phase 4 dataset can be regenerated for comparison.
    cfg.channel.dynamicLOS = true;

    % Correlation distance (m) for the LOS state field. Empty uses the
    % TR 38.901 Table 7.6.3.1-2 value for the scenario (50 m UMa and UMi,
    % 60 m RMa). Set a number here only for a sensitivity study, and
    % record it in the deviations log.
    cfg.channel.losCorrelationDistance_m = [];

    %% ==================================================================
    %  REPLAY FILES
    %  ==================================================================
    cfg.replay = struct();
    cfg.replay.save = true;             % one replay .mat per run
    cfg.replay.format = "-v7.3";        % needed above the 2 GB v7 limit
    cfg.replay.includeNodes = true;     % gNB/UE objects in the bundle;
                                        % false shrinks the file but the
                                        % replay then draws no node marks
    cfg.replay.cullTime = [];           % s; [] culls the settle span only

    %% ==================================================================
    %  SRS CAPACITY
    %  ==================================================================
    % Every UE holds a dedicated uplink link to EVERY gNB so that all
    % cells receive its SRS (configureULforSRS), so the per-gNB UE count
    % equals the total UE count, and the simulator's default SRS
    % configuration caps that at 16. The generator asserts the limit
    % before a run starts rather than letting connectUE fail mid-batch.
    cfg.srs = struct();
    cfg.srs.maxUEsPerGNB = 16;
    % Manual SRS periodicity override in slots. [] leaves the toolbox
    % default. Setting it is the documented route past the 16-UE limit
    % and MUST be recorded in the deviations log when used.
    cfg.srs.periodicitySlots = [];

    %% ==================================================================
    %  SCENARIOS (topology and TR 36.777 parameters; NOT seed dependent)
    %  ==================================================================
    cfg.scenarios = struct();

    % ---- UMa: primary deployment scenario -----------------------------
    s = struct();
    s.zBoundary = 22.5;                 % TR 36.777 Annex B.1: UMa-AV from 22.5 m
    s.avgBuildingHeight = 20;           % m, rooftop reflection (eq B.1.1-2)
    % Table B.1.1-2 (UMa-AV), verified against the source
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

    % ---- RMa: required second fork (rural / isolated protected sites) --
    s = struct();
    s.zBoundary = 10;                   % RMa-AV applies from 10 m
    s.avgBuildingHeight = NaN;          % ground reflection (eq B.1.1-1)
    % Table B.1.1-1 (RMa-AV), verified against the source
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

    % ---- UMi: optional third fork -------------------------------------
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

%% ----------------------------------------------------------------------
function s = trafficSpec(kbps, on, off, pkt)
%trafficSpec One networkTrafficOnOff specification.
    s = struct('dataRate_kbps', kbps, 'onTime_s', on, ...
               'offTime_s', off, 'packetSize_B', pkt);
end
