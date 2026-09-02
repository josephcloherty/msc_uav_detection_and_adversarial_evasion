function [runCfg, meta] = phase5_ScenarioGen(base, seed, scenarioName)
% expands the batch configuration into one concrete run configuration, resolving
% every stochastic quantity up front so the run stays reproducible from the seed.

    %% scenario template
    scenarioName = string(scenarioName);
    assert(isfield(base.scenarios, scenarioName), ...
        'phase5_ScenarioGen:unknownScenario', ...
        'Scenario "%s" is not defined in phase5_Config (have: %s).', ...
        scenarioName, strjoin(string(fieldnames(base.scenarios))', ', '));
    sc   = base.scenarios.(scenarioName);
    topo = sc.topology;

    %% dedicated scenario stream
    s = RandStream('Philox', 'Seed', seed);

    %% fixed topology
    gNBPositions = ringLayout(topo.numGNB, topo.siteRadius_m, ...
        topo.gnbHeight_m, topo.originOffset_m);

    %% aerial population
    % both draws are taken unconditionally so the stream stays aligned
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
             'cfg.srs.periodicitySlots and record the adjustment.'], ...
             numUE, base.srs.maxUEsPerGNB);
    end

    %% placement
    % uniform over the UE region, terrestrial UEs first
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

    %% per-UE traffic
    % three jitter factors per direction per UE, drawn whether used or not
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

    %% mobility bounds
    % addMobility takes the centre convention, [xCentre yCentre width height]
    switch lower(string(base.mobility.boundsConvention))
        case "centre"
            bounds = [ctr(1) ctr(2) span span];
        case "corner"
            bounds = [ctr(1)-span/2 ctr(2)-span/2 span span];
        otherwise
            error('phase5_ScenarioGen:badBoundsConvention', ...
                'cfg.mobility.boundsConvention must be "centre" or "corner".');
    end

    %% assemble the run configuration
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

    % traffic, already jittered
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

    % defaulted here so the value that governed a run is recorded in it
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

    % output and replay, with dataDir resolved rather than guessed later
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

    %% metadata for the manifest
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
    meta.uesPerGNB       = numUE;             % every UE, every gNB
    meta.anchorLoadMax   = max(histcounts(nearest, 0.5:1:(meta.numGNB+0.5)));
    meta.rateJitter      = jitterLog;
end

function P = ringLayout(numGNB, radius, h, origin)
% returns a centre site plus a ring of sites evenly spaced over 360 degrees, so a
% five-site deployment is not lopsided.
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

function v = getOr(s, f, dflt)
% returns a field value with a default, so an older config still loads.
    if isfield(s, f), v = s.(f); else, v = dflt; end
end

function [spec, rateFactor] = jitterSpec(spec, s, rateFrac, timeFrac)
% applies per-UE multiplicative jitter to one traffic specification, always
% taking three draws so the stream advances by a fixed amount.
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
