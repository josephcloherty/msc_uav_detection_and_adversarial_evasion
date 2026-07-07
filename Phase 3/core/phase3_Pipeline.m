function results = phase3_Pipeline(cfg)
%phase3_Pipeline Phase 3 core simulation pipeline (D3.1).
%
%   RESULTS = phase3_Pipeline(CFG) runs one scenario end to end: network
%   build, TR 36.777 / TR 38.901 channel setup, SRS-based per-gNB SINR
%   measurement, handover management, windowed feature extraction, and the
%   schema-locked labelled CSV export. Adapted from the Phase 2 scenario
%   script (phase2_Network_SB.m), itself derived from the Fudan repo
%   scripts; the structural changes for Phase 3 are:
%     - everything is parameterised by the CFG struct so that the UMa,
%       RMa, and UMi forks are thin scenario scripts over one pipeline,
%     - the channel is built by createScenarioChannels (TR 36.777 overlay)
%       and applied by tr36777ChannelModel instead of the flat CDL-C +
%       hNRCustomChannelModel pair,
%     - ground-truth labels come from cfg.ueIsAerial (explicit per-UE
%       class), not from a height heuristic, because an aerial-class UE
%       below the z-boundary is still an aerial UE,
%     - the run ends with extractWindowedFeatures + writeFeatureCSV.
%
%   CFG fields (see phase3_UMa.m for a fully documented example):
%     scenario, seed, zBoundary, carrierFrequency, avgBuildingHeight,
%     av.los / av.nlos (Table B.1.1 rows), gNBPositions, uePositions,
%     ueIsAerial, simulationTime, windowLen, windowStride, visThreshold,
%     rntiOffset, mobility settings, appDataRate, enableShadowFading,
%     enableReplay.
%
%   Reproducibility: rng(cfg.seed) is set once here; all channel and LOS
%   randomness is derived deterministically from cfg.seed (see
%   createScenarioChannels), so a fixed seed regenerates the CSV
%   byte-for-byte (exit criterion for D3.1).

    rng(cfg.seed);   % seed the global stream used by the simulator

    %% initialise networkSim
    networkSimulator = wirelessNetworkSimulator.init;

    %% create gNBs
    gNBNames = "gNB-" + (1:size(cfg.gNBPositions,1));
    gNBs = nrGNB(Name=gNBNames, Position=cfg.gNBPositions, ...
        CarrierFrequency=cfg.carrierFrequency, ChannelBandwidth=20e6, ...
        SubcarrierSpacing=30e3, NumTransmitAntennas=16, ...
        NumReceiveAntennas=8, ReceiveGain=11, DuplexMode="TDD");

    %% create UEs
    UENames = "UE-" + (1:size(cfg.uePositions,1));
    UEs = nrUE(Name=UENames, Position=cfg.uePositions, ...
        NumTransmitAntennas=4, NumReceiveAntennas=2, ReceiveGain=11);
    numsUE = length(UEs);
    assert(numel(cfg.ueIsAerial) == numsUE, ...
        'phase3_Pipeline:labelMismatch', ...
        'cfg.ueIsAerial must have one entry per UE.');

    %% request SRS from all gNBs (per-gNB SINR measurement path, D3.1)
    for i = 1:numsUE
        configureULforSRS(UEs(i), gNBs);
    end

    %% connect UEs to nearest gNB
    rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);
    for u = 1:numsUE
        d = vecnorm(cfg.gNBPositions - UEs(u).Position, 2, 2);
        [~, gIdx] = min(d);
        connectUE(gNBs(gIdx), UEs(u), RLCBearerConfig=rlcBearerConfig);
    end

    %% add nodes
    addNodes(networkSimulator, gNBs);
    addNodes(networkSimulator, UEs);

    %% channel: TR 38.901 terrestrial + TR 36.777 aerial overlay
    % LOS/NLOS is handled entirely by the statistical models (Table B-1 /
    % Table 7.4.2-1 probabilities plus the LOS- and NLOS-specific pathloss
    % rows); the Phase 2 geometric building-blockage add-on was removed
    % (see deviations log).
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

    %% UE traffic
    for ueIdx = 1:numsUE
        ulApps(ueIdx) = networkTrafficOnOff(GeneratePacket=true, ...
            OnTime=inf, OffTime=0, DataRate=cfg.appDataRate); %#ok<AGROW>
        addTrafficSource(UEs(ueIdx), ulApps(ueIdx));
        dlApps(ueIdx) = networkTrafficOnOff(GeneratePacket=true, ...
            OnTime=inf, OffTime=0, DataRate=cfg.appDataRate); %#ok<AGROW>
        addTrafficSource(gNBs(UEs(ueIdx).GNBNodeID), dlApps(ueIdx), ...
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
        % Seed for the TR 36.777 measurement-error stream (decision chain
        % only), derived from the run seed so the run stays reproducible.
        managers{u}.measSeed = cfg.seed*100 + u;
    end

    %% position recorder for post-run replay
    rec = positionRecorder([num2cell(gNBs), num2cell(UEs)], networkSimulator);
    scheduleAction(networkSimulator, @rec.record, [], 1/rec.Rate, 1/rec.Rate);

    %% run
    % Progress reporting. A waitbar window updates in place (percentage,
    % sim time, wall time, ETA), so the command window is not flooded with
    % repeated lines and handover messages cannot corrupt the display.
    % Without a desktop session it falls back to the Phase 2 printed
    % lines. The period is capped at 50 ms of SIM time so the first update
    % appears quickly even on long runs.
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
    fprintf('Done: sim %.2f s in %.1f s wall (%.2fx real-time)\n', ...
        cfg.simulationTime, elapsedWall, cfg.simulationTime / max(elapsedWall, eps));

    %% D3.1: windowed features + schema-locked labelled CSV
    T = extractWindowedFeatures(managers, cfg);
    csvPath = writeFeatureCSV(T, cfg);
    fprintf('Feature CSV (%d rows): %s\n', height(T), csvPath);

    %% handover summary
    S = cellfun(@(m) m.getHandoverStats(), managers);
    for u = 1:numsUE
        fprintf('%-8s [%-11s] HO %d | PP %d\n', UEs(u).Name, ...
            managers{u}.ueLabel, S(u).count, S(u).pingPongCount);
    end

    %% results out (replay optional, off for batch runs)
    % extras carries the scenario config and link states into the replay
    % tool, which uses them to annotate serving lines (LOS probability,
    % ZoD, ZOD offset), colour LOS/NLOS, show the sliding-window features,
    % and mark the settle period. It is embedded in saved replay .mat
    % files, so reloaded replays keep the same display. To replay later:
    %   replayScenario(results.posLog, results.gNBs, results.UEs, ...
    %                  results.managers, [], results.extras)
    extras = struct('cfg', cfg, 'linkInfo', linkInfo);
    results = struct('featureTable', T, 'csvPath', csvPath, ...
        'managers', {managers}, 'gNBs', gNBs, 'UEs', UEs, ...
        'posLog', rec.toStruct(), 'linkInfo', linkInfo, 'extras', extras);
    if cfg.enableReplay
        replayScenario(results.posLog, gNBs, UEs, managers, [], extras);
    end
end

%% local functions (progress reporter adapted from phase2_Network_SB.m)
function p = makeProgressReporter(sim, totalSimTime, wallStart)
    p = struct('sim', sim, 'total', totalSimTime, 'wall', wallStart, 'bar', []);
    if usejava('desktop')
        p.bar = waitbar(0, 'Starting simulation...', ...
            'Name', 'Phase 3 simulation');
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
    msg = sprintf('sim %.2f / %.2f s  |  wall %.0f s  |  ETA %.0f s', ...
        simNow, p.total, elapsedWall, eta);
    if ~isempty(p.bar) && isvalid(p.bar)
        waitbar(frac, p.bar, msg);
    else
        % Fallback (no desktop): the Phase 2 printed line
        fprintf('[%5.1f%%] %s\n', 100*frac, msg);
    end
end

function closeProgress(p)
    if ~isempty(p.bar) && isvalid(p.bar)
        delete(p.bar);
    end
end

