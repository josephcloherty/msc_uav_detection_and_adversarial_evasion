function summary = phase5_Pipeline(cfg)
% runs one Phase 5 scenario end to end, headless, and returns a small plain-data
% summary the batch runner can carry.

    wallStart = tic;
    rng(cfg.seed);   % global stream

    quiet = isfield(cfg, 'quiet') && cfg.quiet;

    %% initialise the simulator
    networkSimulator = wirelessNetworkSimulator.init;

    %% create the gNBs
    r = cfg.radio;
    numgNB = size(cfg.gNBPositions, 1);
    gNBNames = "gNB-" + (1:numgNB);
    gNBs = nrGNB(Name=gNBNames, Position=cfg.gNBPositions, ...
        CarrierFrequency=r.carrierFrequency, ChannelBandwidth=r.channelBandwidth, ...
        SubcarrierSpacing=r.subcarrierSpacing, NumTransmitAntennas=r.gnbTxAntennas, ...
        NumReceiveAntennas=r.gnbRxAntennas, ReceiveGain=r.gnbReceiveGain, ...
        DuplexMode=char(r.duplexMode));

    %% attach a logging scheduler to each gNB, before any connectUE
    scheds = cell(1, numgNB);
    for g = 1:numgNB
        scheds{g} = cqiLoggingScheduler;
        configureScheduler(gNBs(g), Scheduler=scheds{g});
    end

    %% create the UEs
    numsUE = size(cfg.uePositions, 1);
    UENames = "UE-" + (1:numsUE);
    UEs = nrUE(Name=UENames, Position=cfg.uePositions, ...
        NumTransmitAntennas=r.ueTxAntennas, NumReceiveAntennas=r.ueRxAntennas, ...
        ReceiveGain=r.ueReceiveGain);
    assert(numel(cfg.ueIsAerial) == numsUE, ...
        'phase5_Pipeline:labelMismatch', ...
        'cfg.ueIsAerial must have one entry per UE.');
    assert(numel(cfg.trafficPerUE) == numsUE, ...
        'phase5_Pipeline:trafficMismatch', ...
        'cfg.trafficPerUE must have one entry per UE.');

    %% dedicated SRS links to every non-serving gNB
    % the override branch is used only for populations above 16 UEs per gNB
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

    %% connect each UE to its nearest gNB, its anchor for the run
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

    %% resolve and check the RNTI mapping before anything runs
    % the SRS offset cannot be checked until events exist, so it is verified
    % in flight below.
    printMap = ~isfield(cfg, 'printRNTIMap') || cfg.printRNTIMap;
    rntiMap = phase5_ResolveRNTI(cfg, gNBs, UEs, anchorIdx, printMap);
    schedRNTI = rntiMap.sched;

    %% add the nodes to the simulator
    addNodes(networkSimulator, gNBs);
    addNodes(networkSimulator, UEs);

    %% build the channels
    [channels, linkInfo] = createScenarioChannels(cfg, gNBs, UEs);
    channelModel = tr36777ChannelModel(channels, cfg, linkInfo, [UEs.ID]);
    addChannelModel(networkSimulator, ...
        @(rxInfo, txData) channelModel.applyChannelModel(rxInfo, txData));

    %% UE mobility
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

    %% per-UE traffic sources
    ulApps = cell(1, numsUE);
    dlApps = cell(1, numsUE);
    for u = 1:numsUE
        ulApps{u} = makeOnOff(cfg.trafficPerUE(u).ul);
        addTrafficSource(UEs(u), ulApps{u});
        dlApps{u} = makeOnOff(cfg.trafficPerUE(u).dl);
        addTrafficSource(gNBs(anchorIdx(u)), dlApps{u}, DestinationNode=UEs(u));
    end

    %% handover managers
    managers = cell(numsUE, 1);
    for u = 1:numsUE
        if cfg.ueIsAerial(u), lbl = 'aerial'; else, lbl = 'terrestrial'; end
        managers{u} = handoverManager(UEs(u), gNBs, networkSimulator, ...
            ulApps{u}, dlApps{u}, 'eval', lbl, rntiMap.srs(u));
        managers{u}.visThreshold = cfg.visThreshold;
        managers{u}.measSeed = cfg.seed*100 + u;
        applyHandoverConfig(managers{u}, cfg);
    end

    %% in-flight SRS RNTI check, one shot inside the settle window
    % a wrong offset fails silently, so the verifier stops the run early
    if ~isfield(cfg, 'verifyRNTI') || cfg.verifyRNTI
        vOpts = struct('checkTime', cfg.settleTime, ...
            'autoCorrect', isfield(cfg, 'autoCorrectRNTI') && cfg.autoCorrectRNTI, ...
            'quiet', quiet, ...
            'label', sprintf('%s seed %d', cfg.scenario, cfg.seed));
        verifier = rntiVerifier(gNBs, networkSimulator, rntiMap.srs, ...
            managers, vOpts); %#ok<NASGU>
    end

    %% traffic sampler
    sampler = trafficSampler(UEs, networkSimulator);
    scheduleAction(networkSimulator, @sampler.sample, [], ...
        sampler.samplePeriod, sampler.samplePeriod);

    %% position recorder for the replay
    rec = positionRecorder([num2cell(gNBs), num2cell(UEs)], networkSimulator);
    scheduleAction(networkSimulator, @rec.record, [], 1/rec.Rate, 1/rec.Rate);

    %% progress reporting to the batch client
    % a waitbar cannot be drawn from a worker, so the simulated-time fraction
    % goes to the client's queue instead.
    if isfield(cfg, 'progressQueue') && ~isempty(cfg.progressQueue)
        nUpdates = 100;   % one per cent
        if isfield(cfg, 'progress') && isfield(cfg.progress, 'updatesPerRun')
            nUpdates = max(round(cfg.progress.updatesPerRun), 1);
        end
        pq       = cfg.progressQueue;
        thisRun  = cfg.runIdx;
        totalSim = cfg.simulationTime;
        period   = totalSim / nUpdates;
        % send an immediate ping so the client bar flips to running, and
        % carry the worker's own wall time so the ETA is per run.
        send(pq, struct('kind', "progress", 'run', thisRun, 'frac', 0, ...
            'wall', toc(wallStart)));
        scheduleAction(networkSimulator, ...
            @(varargin) send(pq, struct('kind', "progress", ...
                'run', thisRun, ...
                'frac', min(networkSimulator.CurrentTime / totalSim, 1), ...
                'wall', toc(wallStart))), ...
            [], period, period);
    end

    %% run
    % one run() call for the whole simulation, with the CSV written once from
    % the completed logs.
    if ~quiet
        fprintf('[%s seed %d] running %.2f s, %d gNB, %d UE (%d aerial)\n', ...
            cfg.scenario, cfg.seed, cfg.simulationTime, numgNB, numsUE, ...
            sum(cfg.ueIsAerial));
    end

    run(networkSimulator, cfg.simulationTime);
    [T, csvPath] = extractAndWrite(managers, cfg, scheds, sampler, ...
        numgNB, numsUE, anchorIdx, schedRNTI);
    simWall = toc(wallStart);

    %% handover summary
    S = cellfun(@(m) m.getHandoverStats(), managers);
    hoCount = [S.count];
    ppCount = [S.pingPongCount];

    %% LOS diagnostics, analysis only and never a feature column
    % zero transitions across every UE while pLOS swept a wide range is the
    % frozen-state signature.
    posLog  = rec.toStruct();
    losDiag = losDiagnostics(posLog, managers, cfg, linkInfo);

    %% replay bundle
    replayPath = "";
    if isfield(cfg, 'replay') && cfg.replay.save
        % strip runtime-only fields before bundling the config
        cfgSave = cfg;
        for f = {'progressQueue', 'runIdx'}
            if isfield(cfgSave, f{1}), cfgSave = rmfield(cfgSave, f{1}); end
        end
        extras = struct('cfg', cfgSave, 'linkInfo', linkInfo, ...
            'losDiag', losDiag);
        replayPath = saveReplayFile(cfg, posLog, gNBs, UEs, ...
            managers, extras);
    end

    %% plain-data summary
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
    summary.simReached_s  = cfg.simulationTime;   % full length
    summary.truncated     = false;

    % LOS behaviour as scalars for the manifest
    if isempty(losDiag)
        summary.losFractionMean = NaN;
        summary.losTransitions  = NaN;
        summary.losDynamic      = false;
    else
        summary.losFractionMean = mean([losDiag.losFraction]);
        summary.losTransitions  = sum([losDiag.transitions]);
        summary.losDynamic      = all([losDiag.dynamic]);
    end

    % write this run's outcome beside its CSV, so a lost client can be
    % recovered from. wrapped, because a bookkeeping failure must not fail
    % the run.
    try
        phase5_RunInfo('write', cfg, summary);
    catch err
        warning('phase5_Pipeline:runInfoFailed', ...
            '[%s seed %d] could not write the run info sidecar: %s', ...
            cfg.scenario, cfg.seed, err.message);
    end

    if ~quiet
        fprintf('[%s seed %d] %d rows x %d cols in %.1f s wall -> %s\n', ...
            cfg.scenario, cfg.seed, height(T), width(T), simWall, csvPath);
    end
end

function [T, csvPath] = extractAndWrite(managers, cfg, scheds, sampler, ...
        numgNB, numsUE, anchorIdx, schedRNTI)
% extracts the windowed features from the completed logs and writes the CSV.
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
% builds one networkTrafficOnOff from a frozen traffic specification, so no
% draw is made at run time.
    app = networkTrafficOnOff(GeneratePacket=true, ...
        OnTime=spec.onTime_s, OffTime=spec.offTime_s, ...
        DataRate=spec.dataRate_kbps, PacketSize=spec.packetSize_B);
end

function applyHandoverConfig(mgr, cfg)
% pushes the configured mobility-chain values onto one manager, erroring on any
% field that is not a handoverManager property.
    if ~isfield(cfg, 'handover') || isempty(fieldnames(cfg.handover))
        return;
    end
    ctorOnly = {'scanPeriod', 'scanStartTime'};
    f = fieldnames(cfg.handover);
    for k = 1:numel(f)
        assert(isprop(mgr, f{k}), 'phase5_Pipeline:unknownHandoverField', ...
            ['cfg.handover.%s is not a handoverManager property. Fix the ' ...
             'name in phase5_Config, or the run would silently keep the ' ...
             'class default.'], f{k});
        assert(~any(strcmp(f{k}, ctorOnly)), ...
            'phase5_Pipeline:constructionTimeHandoverField', ...
            ['cfg.handover.%s is read by the handoverManager constructor ' ...
             'when it schedules the periodic scan, so setting it here ' ...
             'would be accepted and then ignored. Change the class ' ...
             'default instead.'], f{k});
        mgr.(f{k}) = cfg.handover.(f{k});
    end
end

function connectSRSLinks(UE, gNBs, srsCfg)
% connects the SRS links with an explicit SRS configuration, used only when the
% periodicity override is set.
    rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);
    for i = 2:numel(gNBs)
        try
            connectUE(gNBs(i), UE, RLCBearerConfig=rlcBearerConfig, ...
                SRSConfiguration=srsCfg);
        catch err
            error('phase5_Pipeline:srsOverrideFailed', ...
                ['SRS periodicity override rejected by the toolbox ' ...
                 '(%s). The >16 UEs per gNB constraint has been ' ...
                 'exceeded and the manual adjustment did not take. ' ...
                 'Reduce the UE population or revisit ' ...
                 'cfg.srs.periodicitySlots.'], err.message);
        end
    end
end
