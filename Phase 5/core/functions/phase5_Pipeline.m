function summary = phase5_Pipeline(cfg)
%phase5_Pipeline Headless single-run simulation pipeline for Phase 5 (D5.1).
%
%   SUMMARY = phase5_Pipeline(CFG) runs one scenario end to end and
%   returns a small plain-data summary. CFG is the run configuration
%   produced by phase5_ScenarioGen.
%
%   Adapted from phase4_Pipeline.m. The radio behaviour, measurement
%   chain, feature extraction and CSV writer are unchanged, so a Phase 5
%   row is comparable with a Phase 4 row column for column. The changes
%   are the ones a batch runner needs:
%
%     1. Headless. No waitbar and no interactive replay window, because
%        the run executes on a parallel worker with no display. Progress
%        is optional text on the worker (CFG.quiet), and the client shows
%        batch-level progress instead.
%     2. Per-UE traffic. CFG.trafficPerUE(u).ul/.dl supply one frozen
%        specification per UE per direction rather than one per class, so
%        the seeded rate and timing jitter drawn by the scenario
%        generator reaches the sources. With jitter set to zero this is
%        exactly the Phase 4 per-class behaviour.
%     3. Radio parameters read from CFG.radio rather than hard-coded.
%     4. Optional SRS periodicity override for populations above the
%        default 16 UEs per gNB (CFG.srs.periodicitySlots).
%     5. The replay is written to a .mat bundle instead of being shown.
%        The file is the same structure the interactive replay's Save
%        button produces, so replayScenario(PATH) reopens it directly.
%     6. Returns plain data only. The simulation objects are deliberately
%        NOT returned, so nothing large crosses back from a parfor worker.
%
%   Reproducibility: unchanged from Phase 4. rng(CFG.seed) seeds the
%   global stream the simulator consumes, the channel functions draw from
%   their own seeded streams, and every traffic source is a fixed scalar
%   specification, so the same seed regenerates the CSV byte for byte.

    wallStart = tic;
    rng(cfg.seed);   % global stream consumed by the simulator and mobility

    quiet = isfield(cfg, 'quiet') && cfg.quiet;

    %% initialise networkSim
    networkSimulator = wirelessNetworkSimulator.init;

    %% create gNBs
    r = cfg.radio;
    numgNB = size(cfg.gNBPositions, 1);
    gNBNames = "gNB-" + (1:numgNB);
    gNBs = nrGNB(Name=gNBNames, Position=cfg.gNBPositions, ...
        CarrierFrequency=r.carrierFrequency, ChannelBandwidth=r.channelBandwidth, ...
        SubcarrierSpacing=r.subcarrierSpacing, NumTransmitAntennas=r.gnbTxAntennas, ...
        NumReceiveAntennas=r.gnbRxAntennas, ReceiveGain=r.gnbReceiveGain, ...
        DuplexMode=char(r.duplexMode));

    %% per-gNB CQI/MCS-logging schedulers (before ANY connectUE)
    scheds = cell(1, numgNB);
    for g = 1:numgNB
        scheds{g} = cqiLoggingScheduler;
        configureScheduler(gNBs(g), Scheduler=scheds{g});
    end

    %% create UEs
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
    % Default path is the unmodified Phase 3 helper. When an SRS
    % periodicity override is configured (populations above the default
    % 16 UEs per gNB) the same connection loop is run here with an
    % explicit nrSRSConfig instead; that branch is the documented manual
    % adjustment and must be recorded in the deviations log when used.
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

    %% connect UEs to nearest gNB (= the anchor cell for the whole run)
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

    %% RNTI resolution and pre-run check (both conventions, every run)
    % Scheduler RNTIs are derived from the toolbox connection tables and
    % the whole mapping is validated before anything else happens. The
    % SRS offset cannot be checked until events exist, so it is verified
    % in flight below, inside the settle window.
    printMap = ~isfield(cfg, 'printRNTIMap') || cfg.printRNTIMap;
    rntiMap = phase5_ResolveRNTI(cfg, gNBs, UEs, anchorIdx, printMap);
    schedRNTI = rntiMap.sched;

    %% add nodes
    addNodes(networkSimulator, gNBs);
    addNodes(networkSimulator, UEs);

    %% channel: TR 38.901 terrestrial + TR 36.777 aerial overlay
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

    %% per-UE traffic sources (frozen specifications from the generator)
    ulApps = cell(1, numsUE);
    dlApps = cell(1, numsUE);
    for u = 1:numsUE
        ulApps{u} = makeOnOff(cfg.trafficPerUE(u).ul);
        addTrafficSource(UEs(u), ulApps{u});
        dlApps{u} = makeOnOff(cfg.trafficPerUE(u).dl);
        addTrafficSource(gNBs(anchorIdx(u)), dlApps{u}, DestinationNode=UEs(u));
    end

    %% handover managers (SRS-driven per-gNB SINR, feature logging)
    managers = cell(numsUE, 1);
    for u = 1:numsUE
        if cfg.ueIsAerial(u), lbl = 'aerial'; else, lbl = 'terrestrial'; end
        managers{u} = handoverManager(UEs(u), gNBs, networkSimulator, ...
            ulApps{u}, dlApps{u}, 'eval', lbl, rntiMap.srs(u));
        managers{u}.visThreshold = cfg.visThreshold;
        managers{u}.measSeed = cfg.seed*100 + u;
        applyHandoverConfig(managers{u}, cfg);
    end

    %% in-flight SRS RNTI check (one shot, inside the settle window)
    % The SRS offset is the one identifier still calibrated by hand. A
    % wrong value fails silently: the managers ingest nothing and the run
    % completes after hours with every SINR column NaN. The verifier
    % stops the run at the settle time instead, naming the correction.
    if ~isfield(cfg, 'verifyRNTI') || cfg.verifyRNTI
        vOpts = struct('checkTime', cfg.settleTime, ...
            'autoCorrect', isfield(cfg, 'autoCorrectRNTI') && cfg.autoCorrectRNTI, ...
            'quiet', quiet, ...
            'label', sprintf('%s seed %d', cfg.scenario, cfg.seed));
        verifier = rntiVerifier(gNBs, networkSimulator, rntiMap.srs, ...
            managers, vOpts); %#ok<NASGU>
    end

    %% traffic sampler (0.1 s cumulative byte counters per UE)
    sampler = trafficSampler(UEs, networkSimulator);
    scheduleAction(networkSimulator, @sampler.sample, [], ...
        sampler.samplePeriod, sampler.samplePeriod);

    %% position recorder for post-run replay
    rec = positionRecorder([num2cell(gNBs), num2cell(UEs)], networkSimulator);
    scheduleAction(networkSimulator, @rec.record, [], 1/rec.Rate, 1/rec.Rate);

    %% progress reporting to the batch client
    % The Phase 3 and Phase 4 waitbar cannot be drawn from a parallel
    % worker, so this run's simulated-time fraction is sent to the
    % client's DataQueue instead and aggregated there by phase5_Progress.
    % Absent a queue (a single run driven directly) nothing is scheduled.
    if isfield(cfg, 'progressQueue') && ~isempty(cfg.progressQueue)
        nUpdates = 100;   % one report per per cent of the run
        if isfield(cfg, 'progress') && isfield(cfg.progress, 'updatesPerRun')
            nUpdates = max(round(cfg.progress.updatesPerRun), 1);
        end
        pq       = cfg.progressQueue;
        thisRun  = cfg.runIdx;
        totalSim = cfg.simulationTime;
        period   = totalSim / nUpdates;
        % Immediate 0% ping the moment the worker reaches this point, so
        % the client's bar for this run flips to "running" within seconds
        % of the worker starting rather than after the first simulated
        % period elapses (minutes, at these run speeds). Without it the
        % window sits on grey "pending" bars long enough to look broken.
        % Each report carries this worker's own wall time as well as its
        % simulated fraction. The client turns the pair into a per-run rate,
        % which is the only honest basis for a per-run ETA: a client-side
        % clock would fold in queue latency, and the batch clock says nothing
        % about a run that started late because it waited for a worker.
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
    % One run() call for the whole simulation, and the feature CSV written
    % once from the completed logs. Checkpointing was removed on 28 July:
    % it existed only to survive an overnight machine shutdown, that cause
    % has been dealt with at the machine, and a run that no longer needs to
    % be resumable should not pay for the machinery. Note for anyone
    % reinstating it that run() takes a DURATION and cannot be called twice
    % before R2026a, so segmenting the simulation is not the way to do it;
    % a periodic scheduleAction that re-extracts and rewrites the CSV is.
    if ~quiet
        fprintf('[%s seed %d] running %.2f s, %d gNB, %d UE (%d aerial)\n', ...
            cfg.scenario, cfg.seed, cfg.simulationTime, numgNB, numsUE, ...
            sum(cfg.ueIsAerial));
    end

    run(networkSimulator, cfg.simulationTime);
    [T, csvPath] = extractAndWrite(managers, cfg, scheds, sampler, ...
        numgNB, numsUE, anchorIdx, schedRNTI);
    simWall = toc(wallStart);

    %% handover summary (kept as plain numbers for the manifest)
    S = cellfun(@(m) m.getHandoverStats(), managers);
    hoCount = [S.count];
    ppCount = [S.pingPongCount];

    %% LOS diagnostics (analysis only; NEVER a feature column)
    % LOS state is not an operator observable and is near-collinear with
    % the aerial label, so it stays out of the CSV. It is summarised here
    % so the channel can be checked: transitions == 0 across every UE
    % while pLOS swept a wide range is the frozen-state signature that
    % the Phase 5 spatially-consistent field exists to remove.
    posLog  = rec.toStruct();
    losDiag = losDiagnostics(posLog, managers, cfg, linkInfo);

    %% replay bundle
    replayPath = "";
    if isfield(cfg, 'replay') && cfg.replay.save
        % Runtime-only fields are stripped before the configuration is
        % bundled: the progress queue is a live parallel object that has
        % no meaning once the batch has ended and should not be written
        % into an archived replay.
        cfgSave = cfg;
        for f = {'progressQueue', 'runIdx'}
            if isfield(cfgSave, f{1}), cfgSave = rmfield(cfgSave, f{1}); end
        end
        extras = struct('cfg', cfgSave, 'linkInfo', linkInfo, ...
            'losDiag', losDiag);
        replayPath = saveReplayFile(cfg, posLog, gNBs, UEs, ...
            managers, extras);
    end

    %% plain-data summary (nothing large crosses back from a worker)
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
    summary.simReached_s  = cfg.simulationTime;   % run() returned: full length
    summary.truncated     = false;

    % LOS behaviour, as scalars the batch manifest can carry. A batch whose
    % losTransitions is zero everywhere has a frozen channel state and its
    % dataset should not be trusted for anything LOS-sensitive.
    if isempty(losDiag)
        summary.losFractionMean = NaN;
        summary.losTransitions  = NaN;
        summary.losDynamic      = false;
    else
        summary.losFractionMean = mean([losDiag.losFraction]);
        summary.losTransitions  = sum([losDiag.transitions]);
        summary.losDynamic      = all([losDiag.dynamic]);
    end

    % This run's outcome, recorded beside its CSV by the worker that ran it.
    % The client assembles the manifest from the returned summaries, so if
    % the client dies before the batch returns those summaries are lost even
    % though the runs are on disk. With this, phase5_RebuildManifest can
    % reconstruct the manifest afterwards. Wrapped: a run that has just cost
    % thirty hours must not be reported as failed because a bookkeeping file
    % could not be written.
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

%% ----------------------------------------------------------------------
function [T, csvPath] = extractAndWrite(managers, cfg, scheds, sampler, ...
        numgNB, numsUE, anchorIdx, schedRNTI)
%extractAndWrite Extract windowed features from the logs and write the CSV.
%   Called once, after run() returns, so the manager, scheduler and sampler
%   logs are complete.
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

%% ----------------------------------------------------------------------
function app = makeOnOff(spec)
%makeOnOff One networkTrafficOnOff from a frozen traffic specification.
%   Fixed On/Off scalars keep the source deterministic: no draw is made
%   from any random stream at run time.
    app = networkTrafficOnOff(GeneratePacket=true, ...
        OnTime=spec.onTime_s, OffTime=spec.offTime_s, ...
        DataRate=spec.dataRate_kbps, PacketSize=spec.packetSize_B);
end

%% ----------------------------------------------------------------------
function applyHandoverConfig(mgr, cfg)
%applyHandoverConfig Push the configured mobility-chain values onto one manager.
%   Every field of cfg.handover must name an existing handoverManager
%   property, so a typo in the configuration is caught here rather than
%   being silently ignored and leaving the run on the class defaults.
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
             'default instead, and record it in the deviations log.'], f{k});
        mgr.(f{k}) = cfg.handover.(f{k});
    end
end

%% ----------------------------------------------------------------------
function connectSRSLinks(UE, gNBs, srsCfg)
%connectSRSLinks configureULforSRS with an explicit SRS configuration.
%   Same contract as configureULforSRS (gNBs(1) is left for the caller's
%   own serving connectUE), with the periodicity override applied. Only
%   reached when cfg.srs.periodicitySlots is set, i.e. when the >16 UEs
%   per gNB constraint has been deliberately relaxed. Failure is
%   rethrown with the reason so the constraint is not silently exceeded.
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
