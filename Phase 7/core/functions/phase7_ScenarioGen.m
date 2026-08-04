function [runCfg, meta] = phase7_ScenarioGen(base, seed, scenarioName)
%phase7_ScenarioGen Expand the batch config into one concrete run.
%
%   [RUNCFG, META] = phase7_ScenarioGen(BASE, SEED, SCENARIONAME) flattens
%   phase7_Config into the run configuration phase7_Pipeline expects.
%
%   The scenario supplies everything topological. The seed supplies the
%   aerial UE count, UE start positions, aerial altitudes and per-UE traffic
%   jitter. META reports what was drawn, for the manifest.
%
%   Three generators are used so their draw sequences cannot alias: Philox
%   here, Threefry in createScenarioChannels, and the global stream in the
%   simulator. Everything stochastic is resolved here and written into RUNCFG
%   as fixed numbers.

    scenarioName = string(scenarioName);
    assert(isfield(base.scenarios, scenarioName), ...
        'phase7_ScenarioGen:unknownScenario', ...
        'Scenario "%s" is not defined in phase7_Config (have: %s).', ...
        scenarioName, strjoin(string(fieldnames(base.scenarios))', ', '));
    sc   = base.scenarios.(scenarioName);
    topo = sc.topology;

    s = RandStream('Philox', 'Seed', seed);

    gNBPositions = ringLayout(topo.numGNB, topo.siteRadius_m, ...
        topo.gnbHeight_m, topo.originOffset_m);

    % Both draws are taken unconditionally so the stream advances by the same
    % amount whichever branch is used.
    isMulti  = rand(s) < base.population.pMultiAerial;
    swarmRng = base.population.aerialSwarmSizeRange;
    assert(numel(swarmRng) == 2 && swarmRng(1) >= 1 && swarmRng(2) >= swarmRng(1), ...
        'phase7_ScenarioGen:badSwarmRange', ...
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
            'phase7_ScenarioGen:srsCapacity', ...
            ['%d UEs requested, but every UE holds an SRS link to every ' ...
             'gNB and the default SRS configuration supports %d per gNB. ' ...
             'Reduce cfg.population.numTerrestrialUE or ' ...
             'cfg.population.aerialSwarmSizeRange(2), or set ' ...
             'cfg.srs.periodicitySlots and record the adjustment in the ' ...
             'deviations log.'], numUE, base.srs.maxUEsPerGNB);
    end

    % Uniform over the square UE region, terrestrial UEs first then aerial.
    span = topo.ueAreaSpan_m;
    ctr  = topo.originOffset_m(:)';
    xy   = ctr + (rand(s, numUE, 2) - 0.5) * span;

    % Descending below the overlay floor is a configuration error for an
    % honest run and the entire point of the descent branches, so the guard is
    % gated rather than removed. Only applyEvasion grants the permission.
    allowSubBoundary = isfield(base, 'evasion') && ...
        isfield(base.evasion, 'allowSubBoundary') && base.evasion.allowSubBoundary;
    if ~allowSubBoundary
        assert(sc.aerialAltRange_m(1) > sc.zBoundary, ...
            'phase7_ScenarioGen:altitudeBelowBoundary', ...
            ['Scenario %s: aerialAltRange_m(1) = %.1f m is not above the ' ...
             'TR 36.777 overlay floor zBoundary = %.1f m, so aerial UEs would ' ...
             'be given the terrestrial channel. Set this deliberately only ' ...
             'through an evasion condition.'], scenarioName, ...
            sc.aerialAltRange_m(1), sc.zBoundary);
    elseif sc.aerialAltRange_m(1) <= sc.zBoundary
        % Stated once per run because it changes which propagation model the
        % aerial links use, and that is the mechanism the result is about.
        fprintf(['  %s: aerial band %.1f to %.1f m is at or below the %.1f m ' ...
            'overlay floor, so aerial links take the terrestrial branch.\n'], ...
            scenarioName, sc.aerialAltRange_m(1), sc.aerialAltRange_m(2), ...
            sc.zBoundary);
    end

    z = [repmat(sc.terrestrialAlt_m, numTerr, 1); ...
         sc.aerialAltRange_m(1) + ...
         (sc.aerialAltRange_m(2) - sc.aerialAltRange_m(1)) * rand(s, numAerial, 1)];

    uePositions = [xy, z];
    ueIsAerial  = [false(1, numTerr), true(1, numAerial)];

    % Three jitter factors per direction are drawn whether or not the profile
    % can use them all, so the stream advances identically for every UE.
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

    % "centre" is the convention verified against the recorded Phase 3
    % trajectories.
    switch lower(string(base.mobility.boundsConvention))
        case "centre"
            bounds = [ctr(1) ctr(2) span span];
        case "corner"
            bounds = [ctr(1)-span/2 ctr(2)-span/2 span span];
        otherwise
            error('phase7_ScenarioGen:badBoundsConvention', ...
                'cfg.mobility.boundsConvention must be "centre" or "corner".');
    end

    runCfg = struct();
    runCfg.scenario = scenarioName;
    runCfg.seed     = seed;

    runCfg.zBoundary         = sc.zBoundary;
    runCfg.av                = sc.av;
    runCfg.avgBuildingHeight = sc.avgBuildingHeight;
    if strlength(string(sc.aerialChannelBuilder)) > 0
        runCfg.aerialChannelBuilder = str2func(char(sc.aerialChannelBuilder));
    else
        runCfg.aerialChannelBuilder = [];
    end

    runCfg.carrierFrequency = base.radio.carrierFrequency;
    runCfg.radio            = base.radio;
    runCfg.gNBPositions     = gNBPositions;
    runCfg.uePositions      = uePositions;
    runCfg.ueIsAerial       = logical(ueIsAerial);

    runCfg.enableMobility         = base.mobility.enable;
    runCfg.aerialSpeedRange       = base.mobility.aerialSpeedRange;
    runCfg.terrestrialSpeedRange  = base.mobility.terrestrialSpeedRange;
    runCfg.aerialBounds           = bounds;
    runCfg.terrestrialBounds      = bounds;

    runCfg.trafficPerUE = trafficPerUE;

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

    runCfg.simulationTime = base.window.simulationTime;
    runCfg.windowLen      = base.window.windowLen;
    runCfg.windowStride   = base.window.windowStride;
    runCfg.settleTime     = base.window.settleTime;

    runCfg.enableShadowFading = base.channel.enableShadowFading;

    % Defaulted here as well as in createScenarioChannels, so the value that
    % governed a run ends up in the archived replay.
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

    % writeFeatureCSV's own fallback is relative to its file location and
    % would land in core/data.
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
        'phase7_ScenarioGen:tooShort', ...
        ['simulationTime (%.2f s) must exceed settleTime + windowLen ' ...
         '(%.2f s) or the run produces no feature rows.'], ...
        runCfg.simulationTime, runCfg.settleTime + runCfg.windowLen);

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

function P = ringLayout(numGNB, radius, h, origin)
%ringLayout Centre site plus a ring of sites evenly spaced over 360 deg.
%   Deterministic given the scenario, with a site span of 2*radius. The
%   spacing adapts to the number of ring sites, so six give a hexagon, four a
%   cross and five a pentagon. Taking the first N angles from a fixed 60
%   degree grid instead would leave the 240-300 sector uncovered at five.
    assert(numGNB >= 1 && numGNB <= 13, 'phase7_ScenarioGen:numGNB', ...
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
%getOr Field value with a default, so an older config still loads.
    if isfield(s, f), v = s.(f); else, v = dflt; end
end

function [spec, rateFactor] = jitterSpec(spec, s, rateFrac, timeFrac)
%jitterSpec Apply per-UE multiplicative jitter to one traffic specification.
%   Always takes three draws so the stream advances by a fixed amount.
%   Values are rounded so the frozen spec is identical on any platform.
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
