function results = phase4_Pipeline(cfg)
%phase4_Pipeline Phase 4 core simulation pipeline (D4.1 + D4.2).
%
%   RESULTS = phase4_Pipeline(CFG) runs one scenario end to end. Adapted
%   from phase3_Pipeline.m (kept unchanged alongside for lineage); the
%   structural changes for Phase 4 are:
%     1. Every gNB gets its own cqiLoggingScheduler instance, plugged in
%        with configureScheduler BEFORE any UE connects (ordering
%        requirement of the toolbox). Scheduling decisions are delegated
%        to the stock scheduler, so radio behaviour matches Phase 3; the
%        subclass only logs per-UE CQI/MCS each TTI (D4.1).
%     2. The flat identical-rate OnOff traffic of Phase 3 is replaced by
%        per-class profiles from cfg.traffic: the aerial UEs carry an
%        uplink-heavy steady video profile plus a small downlink C2
%        stream, the terrestrial UEs a downlink-heavy bursty profile
%        (D4.1; per-class parameters live in the scenario script, with
%        sources and the confound discussion in the deviations log).
%     3. A trafficSampler records cumulative per-UE MAC/App byte counters
%        every 0.1 s for the windowed traffic features.
%     4. extractWindowedFeatures now also receives the scheduler logs and
%        the traffic samples, and writeFeatureCSV asserts the Phase 4
%        schema (Phase 3 columns as exact prefix, D4.2).
%
%   Anchor-gNB bookkeeping: each UE's physical data link stays at the gNB
%   it initially attached to (logical handover model, Phase 3 deviations
%   log), so its CQI reports, grants and traffic live in that gNB's
%   scheduler. The pipeline records anchorIdx and the scheduler-log RNTI
%   (UE.ID + cfg.rntiOffset, the empirically verified convention) and
%   hands both to the extraction.
%
%   Reproducibility: unchanged from Phase 3; the traffic sources use
%   deterministic On/Off periods, the scheduler and sampler logs are
%   deterministic functions of the run, so a fixed seed regenerates the
%   CSV byte-for-byte.

    rng(cfg.seed);   % seed the global stream used by the simulator

    %% initialise networkSim
    networkSimulator = wirelessNetworkSimulator.init;

    %% create gNBs
    gNBNames = "gNB-" + (1:size(cfg.gNBPositions,1));
    gNBs = nrGNB(Name=gNBNames, Position=cfg.gNBPositions, ...
        CarrierFrequency=cfg.carrierFrequency, ChannelBandwidth=20e6, ...
        SubcarrierSpacing=30e3, NumTransmitAntennas=16, ...
        NumReceiveAntennas=8, ReceiveGain=11, DuplexMode="TDD");

    %% D4.1: per-gNB CQI/MCS-logging schedulers (before ANY connectUE)
    numgNB = numel(gNBs);
    scheds = cell(1, numgNB);
    for g = 1:numgNB
        scheds{g} = cqiLoggingScheduler;
        configureScheduler(gNBs(g), Scheduler=scheds{g});
    end

    %% create UEs
    UENames = "UE-" + (1:size(cfg.uePositions,1));
    UEs = nrUE(Name=UENames, Position=cfg.uePositions, ...
        NumTransmitAntennas=4, NumReceiveAntennas=2, ReceiveGain=11);
    numsUE = length(UEs);
    assert(numel(cfg.ueIsAerial) == numsUE, ...
        'phase4_Pipeline:labelMismatch', ...
        'cfg.ueIsAerial must have one entry per UE.');

    %% request SRS from all gNBs (per-gNB SINR measurement path)
    for i = 1:numsUE
        configureULforSRS(UEs(i), gNBs);
    end

    %% connect UEs to nearest gNB (= the anchor cell for the whole run)
    rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);
    anchorIdx = zeros(1, numsUE);
    for u = 1:numsUE
        d = vecnorm(cfg.gNBPositions - UEs(u).Position, 2, 2);
        [~, gIdx] = min(d);
        connectUE(gNBs(gIdx), UEs(u), RLCBearerConfig=rlcBearerConfig);
        anchorIdx(u) = gIdx;
    end

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

    %% D4.1: per-class traffic sources (uplink-heavy aerial profile)
    % Parameters come from cfg.traffic.<class>.<dir> (scenario script);
    % makeOnOff below maps one spec struct to a networkTrafficOnOff. All
    % On/Off periods are fixed scalars, so the sources are deterministic
    % and the byte-reproducibility contract holds.
    for ueIdx = 1:numsUE
        if cfg.ueIsAerial(ueIdx), tp = cfg.traffic.aerial;
        else,                     tp = cfg.traffic.terrestrial; end
        ulApps(ueIdx) = makeOnOff(tp.ul); %#ok<AGROW>
        addTrafficSource(UEs(ueIdx), ulApps(ueIdx));
        dlApps(ueIdx) = makeOnOff(tp.dl); %#ok<AGROW>
        addTrafficSource(gNBs(anchorIdx(ueIdx)), dlApps(ueIdx), ...
            DestinationNode=UEs(ueIdx));
    end

    %% handover managers (SRS-driven per-gNB SINR, feature logging)
    managers = cell(numsUE, 1);
    for u = 1:numsUE
        if cfg.ueIsAerial(u), lbl = 'aerial'; else, lbl = 'terrestrial'; end
        rnti = UEs(u).ID + cfg.rntiOffset;
        managers{u} = handoverManager(UEs(u), gNBs, networkSimulator, ...
            ulApps(u), dlApps(u), 'eval', lbl, rnti);
        managers{u}.visThreshold = cfg.visThreshold;
        managers{u}.measSeed = cfg.seed*100 + u;
    end

    %% D4.1: traffic sampler (0.1 s cumulative byte counters per UE)
    sampler = trafficSampler(UEs, networkSimulator);
    scheduleAction(networkSimulator, @sampler.sample, [], ...
        sampler.samplePeriod, sampler.samplePeriod);

    %% position recorder for post-run replay
    rec = positionRecorder([num2cell(gNBs), num2cell(UEs)], networkSimulator);
    scheduleAction(networkSimulator, @rec.record, [], 1/rec.Rate, 1/rec.Rate);

    %% run (progress reporting unchanged from Phase 3)
    wallStart = tic;
    progressPeriod = min(cfg.simulationTime / 100, 0.005);
    prog = makeProgressReporter(networkSimulator, cfg.simulationTime, wallStart);
    progGuard = onCleanup(@() closeProgress(prog));   % close bar on error too
    reportProgress(prog);   % immediate 0% update so the run is visibly alive
    scheduleAction(networkSimulator, @(varargin) reportProgress(prog, varargin{:}), ...
        [], progressPeriod, progressPeriod);

    run(networkSimulator, cfg.simulationTime);
    clear progGuard;   % run finished: close the progress bar

    elapsedWall = toc(wallStart);
    fprintf('Done: sim %.2f s in %s wall (%.2fx real-time)\n', ...
        cfg.simulationTime, fmtDuration(elapsedWall), ...
        cfg.simulationTime / max(elapsedWall, eps));

    %% D4.2: windowed features (SINR/HO + CQI/MCS + traffic) + CSV
    sched = struct('logs', {scheds}, 'anchorIdx', anchorIdx, ...
        'rnti', [UEs.ID] + cfg.rntiOffset);
    T = extractWindowedFeatures(managers, cfg, sched, sampler);
    csvPath = writeFeatureCSV(T, cfg);
    fprintf('Feature CSV (%d rows x %d cols): %s\n', height(T), width(T), csvPath);

    %% handover summary
    S = cellfun(@(m) m.getHandoverStats(), managers);
    for u = 1:numsUE
        fprintf('%-8s [%-11s] HO %d | PP %d\n', UEs(u).Name, ...
            managers{u}.ueLabel, S(u).count, S(u).pingPongCount);
    end

    %% results out (replay optional, off for batch runs)
    extras = struct('cfg', cfg, 'linkInfo', linkInfo);
    results = struct('featureTable', T, 'csvPath', csvPath, ...
        'managers', {managers}, 'gNBs', gNBs, 'UEs', UEs, ...
        'scheds', {scheds}, 'sampler', sampler, 'anchorIdx', anchorIdx, ...
        'posLog', rec.toStruct(), 'linkInfo', linkInfo, 'extras', extras);
    if cfg.enableReplay
        replayScenario(results.posLog, gNBs, UEs, managers, [], extras);
    end
end

%% local functions
function app = makeOnOff(spec)
%makeOnOff One networkTrafficOnOff from a traffic spec struct with fields
% dataRate_kbps, onTime_s, offTime_s, packetSize_B. Fixed On/Off scalars
% keep the source deterministic (no draw from any random stream).
    app = networkTrafficOnOff(GeneratePacket=true, ...
        OnTime=spec.onTime_s, OffTime=spec.offTime_s, ...
        DataRate=spec.dataRate_kbps, PacketSize=spec.packetSize_B);
end

% (progress reporter unchanged from phase3_Pipeline.m)
function p = makeProgressReporter(sim, totalSimTime, wallStart)
    p = struct('sim', sim, 'total', totalSimTime, 'wall', wallStart, 'bar', []);
    if usejava('desktop')
        p.bar = waitbar(0, 'Starting simulation...', ...
            'Name', 'Phase 4 simulation');
    end
end

function reportProgress(p, ~, ~)
    elapsedWall = toc(p.wall);
    simNow      = p.sim.CurrentTime;
    frac        = min(simNow / p.total, 1);
    if frac > 0
        eta = elapsedWall / frac - elapsedWall;
    else
        eta = NaN;
    end
    msg = sprintf('sim %.2f / %.2f s  |  wall %s  |  ETA %s', ...
        simNow, p.total, fmtDuration(elapsedWall), fmtDuration(eta));
    if ~isempty(p.bar) && isvalid(p.bar)
        waitbar(frac, p.bar, msg);
    else
        fprintf('[%5.1f%%] %s\n', 100*frac, msg);
    end
end

function closeProgress(p)
    if ~isempty(p.bar) && isvalid(p.bar)
        delete(p.bar);
    end
end

function s = fmtDuration(secs)
    if ~isfinite(secs)
        s = '--';
        return;
    end
    secs = max(secs, 0);
    if secs < 60
        s = sprintf('%.0f s', secs);
    elseif secs < 3600
        s = sprintf('%d min %02.0f s', floor(secs/60), mod(secs, 60));
    else
        s = sprintf('%d h %d min %02.0f s', floor(secs/3600), ...
            floor(mod(secs, 3600)/60), mod(secs, 60));
    end
end
