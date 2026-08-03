function [runCfg, meta] = phase5_ScenarioGen(base, seed, scenarioName)
%phase5_ScenarioGen Expand the batch config into one concrete run (D5.1).
%
%   [RUNCFG, META] = phase5_ScenarioGen(BASE, SEED, SCENARIONAME) turns
%   the configuration returned by phase5_Config into the flat run
%   configuration that phase5_Pipeline (and, below it, the Phase 3 and
%   Phase 4 channel, measurement and extraction functions) expects.
%
%   SEPARATION OF CONCERNS
%   ----------------------
%   Everything topological comes from BASE.scenarios.(SCENARIONAME) and
%   is therefore identical across every replicate of that scenario: gNB
%   count, positions, heights, carrier, the TR 36.777 aerial parameters
%   and the size of the UE region. Everything stochastic comes from a
%   dedicated random stream seeded from SEED: how many aerial UEs are
%   present, where every UE starts, at what altitude the aerial UEs fly,
%   and the per-UE traffic jitter. The stream used here is Philox, while
%   createScenarioChannels draws its LOS and shadow-fading terms from a
%   Threefry stream and the simulator itself runs off the global stream
%   seeded with rng(SEED); three different generators means the three
%   draw sequences cannot alias onto one another even though they share
%   the same seed value.
%
%   All stochastic quantities are resolved HERE, before the simulation
%   starts, and written into RUNCFG as fixed numbers. The traffic sources
%   the pipeline builds are therefore deterministic, and the whole run
%   remains byte-reproducible from the seed alone.
%
%   META reports what was drawn (aerial count, altitudes, jitter factors,
%   UE-per-gNB load) for the batch manifest.
%
%   SRS CAPACITY
%   ------------
%   configureULforSRS gives every UE a dedicated uplink link to every gNB,
%   so the per-gNB UE count equals the TOTAL UE count rather than the
%   count anchored to that cell. The simulator's default SRS configuration
%   supports 16 UEs per gNB, so the check below is on the total. It is
%   made here, before any object is created, so an over-sized population
%   fails immediately with an actionable message instead of erroring
%   inside connectUE partway through a batch.

    %% ---- scenario template -------------------------------------------
    scenarioName = string(scenarioName);
    assert(isfield(base.scenarios, scenarioName), ...
        'phase5_ScenarioGen:unknownScenario', ...
        'Scenario "%s" is not defined in phase5_Config (have: %s).', ...
        scenarioName, strjoin(string(fieldnames(base.scenarios))', ', '));
    sc   = base.scenarios.(scenarioName);
    topo = sc.topology;

    %% ---- dedicated scenario stream ------------------------------------
    s = RandStream('Philox', 'Seed', seed);

    %% ---- fixed topology ------------------------------------------------
    gNBPositions = ringLayout(topo.numGNB, topo.siteRadius_m, ...
        topo.gnbHeight_m, topo.originOffset_m);

    %% ---- aerial population ---------------------------------------------
    % One draw decides single versus multi, a second draws the group size.
    % Both are taken unconditionally so the stream advances by the same
    % amount whichever branch is taken, keeping later draws aligned.
    isMulti  = rand(s) < base.population.pMultiAerial;
    swarmRng = base.population.aerialSwarmSizeRange;
    assert(numel(swarmRng) == 2 && swarmRng(1) >= 1 && swarmRng(2) >= swarmRng(1), ...
        'phase5_ScenarioGen:badSwarmRange', ...
        'cfg.population.aerialSwarmSizeRange must be [min max] with 1 <= min <= max.');
    swarmSize = randi(s, [swarmRng(1) swarmRng(2)]);
    if isMulti
        numAerial = swarmSize;
    else
        numAerial = base.population.singleAerialCount;
    end
    numTerr = base.population.numTerrestrialUE;
    numUE   = numTerr + numAerial;

    if isempty(base.srs.periodicitySlots)
        assert(numUE <= base.srs.maxUEsPerGNB, ...
            'phase5_ScenarioGen:srsCapacity', ...
            ['%d UEs requested, but every UE holds an SRS link to every ' ...
             'gNB and the default SRS configuration supports %d per gNB. ' ...
             'Reduce cfg.population.numTerrestrialUE or ' ...
             'cfg.population.aerialSwarmSizeRange(2), or set ' ...
             'cfg.srs.periodicitySlots and record the adjustment in the ' ...
             'deviations log.'], numUE, base.srs.maxUEsPerGNB);
    end

    %% ---- placement -------------------------------------------------------
    % Uniform over the square UE region centred on the layout origin.
    % Terrestrial UEs first, then aerial, matching the Phase 3/4 ordering.
    span = topo.ueAreaSpan_m;
    ctr  = topo.originOffset_m(:)';
    xy   = ctr + (rand(s, numUE, 2) - 0.5) * span;

    assert(sc.aerialAltRange_m(1) > sc.zBoundary, ...
        'phase5_ScenarioGen:altitudeBelowBoundary', ...
        ['Scenario %s: aerialAltRange_m(1) = %.1f m is not above the ' ...
         'TR 36.777 overlay floor zBoundary = %.1f m, so aerial UEs would ' ...
         'be given the terrestrial channel.'], scenarioName, ...
        sc.aerialAltRange_m(1), sc.zBoundary);

    z = [repmat(sc.terrestrialAlt_m, numTerr, 1); ...
         sc.aerialAltRange_m(1) + ...
         (sc.aerialAltRange_m(2) - sc.aerialAltRange_m(1)) * rand(s, numAerial, 1)];

    uePositions = [xy, z];
    ueIsAerial  = [false(1, numTerr), true(1, numAerial)];

    %% ---- per-UE traffic --------------------------------------------------
    % Three jitter factors are drawn per direction per UE regardless of
    % whether the profile can use all three, so the stream advances
    % identically for every UE and class.
    rj = base.traffic.rateJitterFrac;
    tj = base.traffic.timingJitterFrac;
    trafficPerUE = repmat(struct('ul', [], 'dl', []), 1, numUE);
    jitterLog = zeros(numUE, 2);
    for u = 1:numUE
        if ueIsAerial(u), prof = base.traffic.aerial;
        else,             prof = base.traffic.terrestrial; end
        [trafficPerUE(u).ul, fUL] = jitterSpec(prof.ul, s, rj, tj);
        [trafficPerUE(u).dl, fDL] = jitterSpec(prof.dl, s, rj, tj);
        jitterLog(u, :) = [fUL fDL];
    end

    %% ---- mobility bounds --------------------------------------------------
    % addMobility takes a four-element Bounds vector. The "centre"
    % convention, [xCentre yCentre width height], is the one verified
    % against the recorded Phase 3 trajectories (aerial UEs reached
    % coordinates only reachable under that reading).
    switch lower(string(base.mobility.boundsConvention))
        case "centre"
            bounds = [ctr(1) ctr(2) span span];
        case "corner"
            bounds = [ctr(1)-span/2 ctr(2)-span/2 span span];
        otherwise
            error('phase5_ScenarioGen:badBoundsConvention', ...
                'cfg.mobility.boundsConvention must be "centre" or "corner".');
    end

    %% ---- assemble the run configuration ------------------------------------
    runCfg = struct();
    runCfg.scenario = scenarioName;
    runCfg.seed     = seed;

    % TR 36.777 overlay
    runCfg.zBoundary         = sc.zBoundary;
    runCfg.av                = sc.av;
    runCfg.avgBuildingHeight = sc.avgBuildingHeight;
    if strlength(string(sc.aerialChannelBuilder)) > 0
        runCfg.aerialChannelBuilder = str2func(char(sc.aerialChannelBuilder));
    else
        runCfg.aerialChannelBuilder = [];
    end

    % radio and geometry
    runCfg.carrierFrequency = base.radio.carrierFrequency;
    runCfg.radio            = base.radio;
    runCfg.gNBPositions     = gNBPositions;
    runCfg.uePositions      = uePositions;
    runCfg.ueIsAerial       = logical(ueIsAerial);

    % mobility
    runCfg.enableMobility         = base.mobility.enable;
    runCfg.aerialSpeedRange       = base.mobility.aerialSpeedRange;
    runCfg.terrestrialSpeedRange  = base.mobility.terrestrialSpeedRange;
    runCfg.aerialBounds           = bounds;
    runCfg.terrestrialBounds      = bounds;

    % traffic (per UE, already jittered and frozen)
    runCfg.trafficPerUE = trafficPerUE;

    % measurement and handover chain
    runCfg.rntiOffset      = base.measurement.rntiOffset;
    runCfg.visThreshold    = base.measurement.visThreshold;
    runCfg.verifyRNTI      = getOr(base.measurement, 'verifyRNTI', true);
    runCfg.autoCorrectRNTI = getOr(base.measurement, 'autoCorrectRNTI', false);
    runCfg.printRNTIMap    = getOr(base.measurement, 'printRNTIMap', true);
    if isfield(base, 'handover')
        runCfg.handover = base.handover;
    else
        runCfg.handover = struct();
    end

    % windowing
    runCfg.simulationTime = base.window.simulationTime;
    runCfg.windowLen      = base.window.windowLen;
    runCfg.windowStride   = base.window.windowStride;
    runCfg.settleTime     = base.window.settleTime;

    % channel and SRS
    runCfg.enableShadowFading = base.channel.enableShadowFading;

    % Dynamic LOS state and its correlation distance. Defaulted here (not
    % only in createScenarioChannels) so the value that governed a run is
    % recorded in the run configuration, and therefore in the archived
    % replay bundle, rather than being implicit in the code version.
    if isfield(base.channel, 'dynamicLOS')
        runCfg.dynamicLOS = base.channel.dynamicLOS;
    else
        runCfg.dynamicLOS = true;
    end
    if isfield(base.channel, 'losCorrelationDistance_m')
        runCfg.losCorrelationDistance_m = base.channel.losCorrelationDistance_m;
    else
        runCfg.losCorrelationDistance_m = [];
    end
    runCfg.srs                = base.srs;

    % output and replay. An empty dataDir resolves to <Phase 5>/data here
    % rather than being left for writeFeatureCSV to guess, whose own
    % fallback is relative to its file location and would land in
    % core/data now that it lives one folder deeper.
    if strlength(string(base.batch.dataDir)) == 0
        runCfg.outputDir = string(fullfile(fileparts(mfilename('fullpath')), ...
            '..', '..', 'data'));
    else
        runCfg.outputDir = string(base.batch.dataDir);
    end
    runCfg.replay        = base.replay;
    runCfg.enableReplay  = base.replay.save;
    runCfg.quiet         = ~base.batch.verboseWorkers;
    if isfield(base, 'progress')
        runCfg.progress = base.progress;
    end
    if ~isempty(base.replay.cullTime)
        runCfg.replayCullTime = base.replay.cullTime;
    end

    assert(runCfg.simulationTime > runCfg.windowLen + runCfg.settleTime, ...
        'phase5_ScenarioGen:tooShort', ...
        ['simulationTime (%.2f s) must exceed settleTime + windowLen ' ...
         '(%.2f s) or the run produces no feature rows.'], ...
        runCfg.simulationTime, runCfg.settleTime + runCfg.windowLen);

    %% ---- metadata for the manifest -------------------------------------------
    d = vecnorm(reshape(gNBPositions, [], 1, 3) - reshape(uePositions, 1, [], 3), 2, 3);
    [~, nearest] = min(d, [], 1);
    meta = struct();
    meta.scenario        = scenarioName;
    meta.seed            = seed;
    meta.numGNB          = size(gNBPositions, 1);
    meta.siteRadius_m    = topo.siteRadius_m;
    meta.ueAreaSpan_m    = span;
    meta.numUE           = numUE;
    meta.numTerrestrial  = numTerr;
    meta.numAerial       = numAerial;
    meta.isMultiAerial   = isMulti;
    meta.aerialFraction  = numAerial / numUE;
    meta.aerialAlt_m     = z(numTerr+1:end)';
    meta.uesPerGNB       = numUE;             % SRS links: every UE, every gNB
    meta.anchorLoadMax   = max(histcounts(nearest, 0.5:1:(meta.numGNB+0.5)));
    meta.rateJitter      = jitterLog;
end

%% --------------------------------------------------------------------------
function P = ringLayout(numGNB, radius, h, origin)
%ringLayout Centre site plus a ring of sites EVENLY spaced over 360 deg.
%   Deterministic given the scenario, so the topology is a property of the
%   scenario and not of the run. Site span is 2*radius across the ring.
%
%   The angular spacing adapts to the number of ring sites: six ring sites
%   give the usual hexagon, four give a cross, five a pentagon. Taking the
%   first N angles from a fixed 60 degree grid instead, which is the
%   obvious implementation, would place five sites at 0, 60, 120 and 180
%   degrees and leave the whole 240 to 300 degree sector uncovered, so a
%   five-site deployment would be lopsided and every UE in that sector
%   would see an unrepresentative cell count.
    assert(numGNB >= 1 && numGNB <= 13, 'phase5_ScenarioGen:numGNB', ...
        ['topology.numGNB must be between 1 and 13 (centre site plus a ' ...
         'ring of up to twelve). D5.1 specifies 5 to 7.']);
    nRing = numGNB - 1;
    P = [origin(1) origin(2) h];
    if nRing > 0
        ang = (0:nRing-1) * (360/nRing);
        for k = 1:nRing
            P(end+1, :) = [origin(1) + radius*cosd(ang(k)), ...
                           origin(2) + radius*sind(ang(k)), h]; %#ok<AGROW>
        end
    end
end

%% --------------------------------------------------------------------------
function v = getOr(s, f, dflt)
%getOr Field value with a default, so an older config still loads.
    if isfield(s, f), v = s.(f); else, v = dflt; end
end

%% --------------------------------------------------------------------------
function [spec, rateFactor] = jitterSpec(spec, s, rateFrac, timeFrac)
%jitterSpec Apply per-UE multiplicative jitter to one traffic specification.
%   Three uniform draws are always taken so the stream advances by a fixed
%   amount per direction per UE. Values are rounded (rate to 0.1 kbps,
%   times to 1 ms) so the frozen specification stays readable in the saved
%   configuration and identical on any platform.
    r = rand(s, 1, 3);
    rateFactor = 1 + rateFrac * (2*r(1) - 1);
    spec.dataRate_kbps = round(spec.dataRate_kbps * rateFactor, 1);
    if isfinite(spec.onTime_s) && spec.onTime_s > 0
        spec.onTime_s = round(spec.onTime_s * (1 + timeFrac*(2*r(2)-1)), 3);
    end
    if isfinite(spec.offTime_s) && spec.offTime_s > 0
        spec.offTime_s = round(spec.offTime_s * (1 + timeFrac*(2*r(3)-1)), 3);
    end
end
