function summary = phase7_Pipeline(cfg)
%phase7_Pipeline Headless single-run simulation pipeline.
%
%   SUMMARY = phase7_Pipeline(CFG) runs one scenario end to end and returns a
%   small plain-data summary, where CFG comes from phase7_ScenarioGen.
%
%   The radio behaviour, measurement chain, feature extraction and CSV writer
%   are unchanged from Phase 4. Differences from the Phase 4 script:
%     - headless; the run executes on a worker with no display
%     - per-UE traffic from CFG.trafficPerUE rather than one spec per class
%     - radio parameters read from CFG.radio instead of hard-coded
%     - optional SRS periodicity override for more than 16 UEs per gNB
%     - the replay written to a .mat bundle instead of shown
%     - plain data returned, so nothing large crosses back from a worker
%
%   Same seed regenerates the CSV byte for byte.

    wallStart = tic;
    rng(cfg.seed);   % global stream consumed by the simulator and mobility

    quiet = isfield(cfg, 'quiet') && cfg.quiet;

    networkSimulator = wirelessNetworkSimulator.init;

    r = cfg.radio;
    numgNB = size(cfg.gNBPositions, 1);
    gNBNames = "gNB-" + (1:numgNB);
    gNBs = nrGNB(Name=gNBNames, Position=cfg.gNBPositions, ...
        CarrierFrequency=r.carrierFrequency, ChannelBandwidth=r.channelBandwidth, ...
        SubcarrierSpacing=r.subcarrierSpacing, NumTransmitAntennas=r.gnbTxAntennas, ...
        NumReceiveAntennas=r.gnbRxAntennas, ReceiveGain=r.gnbReceiveGain, ...
        DuplexMode=char(r.duplexMode));

    % Must be configured before any connectUE.
    scheds = cell(1, numgNB);
    for g = 1:numgNB
        scheds{g} = cqiLoggingScheduler;
        configureScheduler(gNBs(g), Scheduler=scheds{g});
    end

    numsUE = size(cfg.uePositions, 1);
    UENames = "UE-" + (1:numsUE);
    UEs = nrUE(Name=UENames, Position=cfg.uePositions, ...
        NumTransmitAntennas=r.ueTxAntennas, NumReceiveAntennas=r.ueRxAntennas, ...
        ReceiveGain=r.ueReceiveGain);
    assert(numel(cfg.ueIsAerial) == numsUE, ...
        'phase7_Pipeline:labelMismatch', ...
        'cfg.ueIsAerial must have one entry per UE.');
    assert(numel(cfg.trafficPerUE) == numsUE, ...
        'phase7_Pipeline:trafficMismatch', ...
        'cfg.trafficPerUE must have one entry per UE.');

    % Dedicated SRS links to every non-serving gNB. The override branch runs
    % the same loop with an explicit nrSRSConfig and must be recorded in the
    % deviations log when used.
    srsOverride = [];
    if isfield(cfg, 'srs') && ~isempty(cfg.srs.periodicitySlots)
        srsOverride = nrSRSConfig(SRSPeriod=[cfg.srs.periodicitySlots 0]);
    end
    for i = 1:numsUE
        if isempty(srsOverride)
            configureULforSRS(UEs(i), gNBs);
        else
            connectSRSLinks(UEs(i), gNBs, srsOverride);
        end
    end

    % Nearest gNB is the anchor cell for the whole run.
    rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);
    anchorIdx = zeros(1, numsUE);
    for u = 1:numsUE
        d = vecnorm(cfg.gNBPositions - UEs(u).Position, 2, 2);
        [~, gIdx] = min(d);
        if isempty(srsOverride)
            connectUE(gNBs(gIdx), UEs(u), RLCBearerConfig=rlcBearerConfig);
        else
            connectUE(gNBs(gIdx), UEs(u), RLCBearerConfig=rlcBearerConfig, ...
                SRSConfiguration=srsOverride);
        end
        anchorIdx(u) = gIdx;
    end

    % The SRS offset cannot be checked until events exist, so that part
    % happens in flight below.
    printMap = ~isfield(cfg, 'printRNTIMap') || cfg.printRNTIMap;
    rntiMap = phase7_ResolveRNTI(cfg, gNBs, UEs, anchorIdx, printMap);
    schedRNTI = rntiMap.sched;

    addNodes(networkSimulator, gNBs);
    addNodes(networkSimulator, UEs);

    % TR 38.901 terrestrial with the TR 36.777 aerial overlay.
    [channels, linkInfo] = createScenarioChannels(cfg, gNBs, UEs);
    channelModel = tr36777ChannelModel(channels, cfg, linkInfo, [UEs.ID]);
    addChannelModel(networkSimulator, ...
        @(rxInfo, txData) channelModel.applyChannelModel(rxInfo, txData));

    if cfg.enableMobility
        for u = 1:numsUE
            if cfg.ueIsAerial(u)
                addMobility(UEs(u), SpeedRange=cfg.aerialSpeedRange, ...
                    BoundaryShape="rectangle", Bounds=cfg.aerialBounds);
            else
                addMobility(UEs(u), SpeedRange=cfg.terrestrialSpeedRange, ...
                    BoundaryShape="rectangle", Bounds=cfg.terrestrialBounds);
            end
        end
    end

    ulApps = cell(1, numsUE);
    dlApps = cell(1, numsUE);
    for u = 1:numsUE
        ulApps{u} = makeOnOff(cfg.trafficPerUE(u).ul);
        addTrafficSource(UEs(u), ulApps{u});
        dlApps{u} = makeOnOff(cfg.trafficPerUE(u).dl);
        addTrafficSource(gNBs(anchorIdx(u)), dlApps{u}, DestinationNode=UEs(u));
    end

    managers = cell(numsUE, 1);
    for u = 1:numsUE
        if cfg.ueIsAerial(u), lbl = 'aerial'; else, lbl = 'terrestrial'; end
        managers{u} = handoverManager(UEs(u), gNBs, networkSimulator, ...
            ulApps{u}, dlApps{u}, 'eval', lbl, rntiMap.srs(u));
        managers{u}.visThreshold = cfg.visThreshold;
        managers{u}.measSeed = cfg.seed*100 + u;
        applyHandoverConfig(managers{u}, cfg);
    end

    % One shot inside the settle window; a wrong offset otherwise fails
    % silently and wastes the whole run.
    if ~isfield(cfg, 'verifyRNTI') || cfg.verifyRNTI
        vOpts = struct('checkTime', cfg.settleTime, ...
            'autoCorrect', isfield(cfg, 'autoCorrectRNTI') && cfg.autoCorrectRNTI, ...
            'quiet', quiet, ...
            'label', sprintf('%s seed %d', cfg.scenario, cfg.seed));
        verifier = rntiVerifier(gNBs, networkSimulator, rntiMap.srs, ...
            managers, vOpts); %#ok<NASGU>
    end

    sampler = trafficSampler(UEs, networkSimulator);
    scheduleAction(networkSimulator, @sampler.sample, [], ...
        sampler.samplePeriod, sampler.samplePeriod);

    rec = positionRecorder([num2cell(gNBs), num2cell(UEs)], networkSimulator);
    scheduleAction(networkSimulator, @rec.record, [], 1/rec.Rate, 1/rec.Rate);

    % With no queue, as when a single run is driven directly, nothing is
    % scheduled.
    if isfield(cfg, 'progressQueue') && ~isempty(cfg.progressQueue)
        nUpdates = 100;   % one report per per cent of the run
        if isfield(cfg, 'progress') && isfield(cfg.progress, 'updatesPerRun')
            nUpdates = max(round(cfg.progress.updatesPerRun), 1);
        end
        pq       = cfg.progressQueue;
        thisRun  = cfg.runIdx;
        totalSim = cfg.simulationTime;
        period   = totalSim / nUpdates;
        % Ping 0% straight away so the run shows as started within seconds
        % rather than after the first simulated period elapses.
        send(pq, struct('kind', "progress", 'run', thisRun, 'frac', 0, ...
            'wall', toc(wallStart)));
        scheduleAction(networkSimulator, ...
            @(varargin) send(pq, struct('kind', "progress", ...
                'run', thisRun, ...
                'frac', min(networkSimulator.CurrentTime / totalSim, 1), ...
                'wall', toc(wallStart))), ...
            [], period, period);
    end

    % One run() call for the whole simulation. Checkpointing would have to go
    % through a periodic scheduleAction: run() takes a duration and cannot be
    % called twice before R2026a.
    if ~quiet
        fprintf('[%s seed %d] running %.2f s, %d gNB, %d UE (%d aerial)\n', ...
            cfg.scenario, cfg.seed, cfg.simulationTime, numgNB, numsUE, ...
            sum(cfg.ueIsAerial));
    end

    run(networkSimulator, cfg.simulationTime);
    [T, csvPath] = extractAndWrite(managers, cfg, scheds, sampler, ...
        numgNB, numsUE, anchorIdx, schedRNTI);
    simWall = toc(wallStart);

    S = cellfun(@(m) m.getHandoverStats(), managers);
    hoCount = [S.count];
    ppCount = [S.pingPongCount];

    % Analysis only, never a feature column.
    posLog  = rec.toStruct();
    losDiag = losDiagnostics(posLog, managers, cfg, linkInfo);

    replayPath = "";
    if isfield(cfg, 'replay') && cfg.replay.save
        % The progress queue is a live parallel object with no meaning in an
        % archived replay.
        cfgSave = cfg;
        for f = {'progressQueue', 'runIdx'}
            if isfield(cfgSave, f{1}), cfgSave = rmfield(cfgSave, f{1}); end
        end
        extras = struct('cfg', cfgSave, 'linkInfo', linkInfo, ...
            'losDiag', losDiag);
        replayPath = saveReplayFile(cfg, posLog, gNBs, UEs, ...
            managers, extras);
    end

    summary = struct();
    summary.scenario      = string(cfg.scenario);
    summary.seed          = cfg.seed;
    summary.numGNB        = numgNB;
    summary.numUE         = numsUE;
    summary.numAerial     = sum(cfg.ueIsAerial);
    summary.numRows       = height(T);
    summary.numCols       = width(T);
    summary.csvPath       = string(csvPath);
    summary.replayPath    = string(replayPath);
    summary.wallTime_s    = simWall;
    summary.hoCountTotal  = sum(hoCount);
    summary.hoCountAerial = sum(hoCount(cfg.ueIsAerial));
    summary.pingPongTotal = sum(ppCount);
    summary.matlabRelease = string(version('-release'));
    summary.simReached_s  = cfg.simulationTime;   % run() returned, so full
    summary.truncated     = false;

    % losTransitions zero everywhere means a frozen channel state, which is
    % not trustworthy for anything LOS-sensitive.
    if isempty(losDiag)
        summary.losFractionMean = NaN;
        summary.losTransitions  = NaN;
        summary.losDynamic      = false;
    else
        summary.losFractionMean = mean([losDiag.losFraction]);
        summary.losTransitions  = sum([losDiag.transitions]);
        summary.losDynamic      = all([losDiag.dynamic]);
    end

    if ~quiet
        fprintf('[%s seed %d] %d rows x %d cols in %.1f s wall -> %s\n', ...
            cfg.scenario, cfg.seed, height(T), width(T), simWall, csvPath);
    end
end

function [T, csvPath] = extractAndWrite(managers, cfg, scheds, sampler, ...
        numgNB, numsUE, anchorIdx, schedRNTI)
%extractAndWrite Extract windowed features from the logs and write the CSV.
%   Called once after run() returns, so every log is complete.
    ctxs = cell(1, numgNB); grs = cell(1, numgNB);
    for g = 1:numgNB
        [ctxs{g}, grs{g}] = scheds{g}.getLogs();
    end
    trafficLogs = arrayfun(@(u) sampler.getLog(u), 1:numsUE, ...
        'UniformOutput', false);
    sched = struct('ctx', {ctxs}, 'grants', {grs}, ...
        'anchorIdx', anchorIdx, 'rnti', schedRNTI);
    T = extractWindowedFeatures(managers, cfg, sched, trafficLogs);
    csvPath = writeFeatureCSV(T, cfg);
end

function app = makeOnOff(spec)
%makeOnOff One networkTrafficOnOff from a frozen traffic specification.
%   Fixed On/Off scalars keep the source deterministic at run time.
    app = networkTrafficOnOff(GeneratePacket=true, ...
        OnTime=spec.onTime_s, OffTime=spec.offTime_s, ...
        DataRate=spec.dataRate_kbps, PacketSize=spec.packetSize_B);
end

function applyHandoverConfig(mgr, cfg)
%applyHandoverConfig Push the configured mobility-chain values onto one manager.
%   Every field must name a real handoverManager property, so a typo is
%   caught here instead of silently leaving the run on the class defaults.
    if ~isfield(cfg, 'handover') || isempty(fieldnames(cfg.handover))
        return;
    end
    ctorOnly = {'scanPeriod', 'scanStartTime'};
    f = fieldnames(cfg.handover);
    for k = 1:numel(f)
        assert(isprop(mgr, f{k}), 'phase7_Pipeline:unknownHandoverField', ...
            ['cfg.handover.%s is not a handoverManager property. Fix the ' ...
             'name in phase7_Config, or the run would silently keep the ' ...
             'class default.'], f{k});
        assert(~any(strcmp(f{k}, ctorOnly)), ...
            'phase7_Pipeline:constructionTimeHandoverField', ...
            ['cfg.handover.%s is read by the handoverManager constructor ' ...
             'when it schedules the periodic scan, so setting it here ' ...
             'would be accepted and then ignored. Change the class ' ...
             'default instead, and record it in the deviations log.'], f{k});
        mgr.(f{k}) = cfg.handover.(f{k});
    end
end

function connectSRSLinks(UE, gNBs, srsCfg)
%connectSRSLinks configureULforSRS with an explicit SRS configuration.
%   Same contract as configureULforSRS, with the periodicity override
%   applied, and only reached when cfg.srs.periodicitySlots is set.
    rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);
    for i = 2:numel(gNBs)
        try
            connectUE(gNBs(i), UE, RLCBearerConfig=rlcBearerConfig, ...
                SRSConfiguration=srsCfg);
        catch err
            error('phase7_Pipeline:srsOverrideFailed', ...
                ['SRS periodicity override rejected by the toolbox ' ...
                 '(%s). The >16 UEs per gNB constraint has been ' ...
                 'exceeded and the manual adjustment did not take. ' ...
                 'Reduce the UE population or revisit ' ...
                 'cfg.srs.periodicitySlots.'], err.message);
        end
    end
end
