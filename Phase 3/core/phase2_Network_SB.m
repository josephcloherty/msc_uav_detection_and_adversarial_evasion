clc; clear; % clean workspace
rng("default") % set RNG seed

%% initialise networkSim
networkSimulator = wirelessNetworkSimulator.init; 

%% create gNBs
spacing = 500;
gNBPositions = [ ...
    %spacing  2*spacing  25; % top right
    %0  2*spacing  25; % top left
    %spacing/2+spacing  spacing  25; % middle right
    %spacing/2-spacing  spacing  25; % middle left
    spacing/2  spacing  25; % middle middle
    spacing  0  25; % bottom right
    0  0  25]; % bottom left  
gNBNames = "gNB-" + (1:size(gNBPositions,1));
gNBs = nrGNB(Name=gNBNames,Position=gNBPositions,CarrierFrequency=2.6e9,ChannelBandwidth=20e6,SubcarrierSpacing=30e3,...
    NumTransmitAntennas=16,NumReceiveAntennas=8,ReceiveGain=11,DuplexMode="TDD");

%% create UEs
uePositions = [ ...
    -6 100 1.5; % Terrestrial
    -32 20 1.5;
    80 350 1.5;
    122 220 1.5;
    110 413 1.5;
     200 0  100
     -50 130 120]; % Aerial
UENames = "UE-" + (1:size(uePositions,1));
UEs= nrUE(Name=UENames,Position=uePositions,NumTransmitAntennas=4,NumReceiveAntennas=2,ReceiveGain=11);
numsUE=length(UEs);

%% Buildings: x center, y center, x width, y width, height

buildingsRaw = [ ...
    %150 0 40 60 80;
    %150 80 40 60 55;
    %150 160 40 60 35;
    %150 240 40 60 90;
    %200 300 100 40 30;
    %-40 300 60 40 45;
    %40 300 60 40 35;
    %120 300 60 40 60;
    %-100 0 40 60 70;
    %-100 80 40 60 35;
    %-100 160 40 60 45;
    %-100 240 40 60 30
    0 0 0 0 0];     % building between gNB and the 200 m UE


% convert to axis-aligned min/max extents: [xmin xmax ymin ymax zmin zmax]
buildingsAABB = [ ...
    buildingsRaw(:,1)-buildingsRaw(:,3)/2, buildingsRaw(:,1)+buildingsRaw(:,3)/2, ...
    buildingsRaw(:,2)-buildingsRaw(:,4)/2, buildingsRaw(:,2)+buildingsRaw(:,4)/2, ...
    zeros(size(buildingsRaw,1),1),         buildingsRaw(:,5)];

blockageDB = 45;   % attenuation added per building the LoS segment crosses



%% request SRS (Sounding Reference Signals) from ann gNBs in the scenario
for i=1:numsUE
    configureULforSRS(UEs(i),gNBs);
end

%% create and configure RLC (Radio Link Control) layer
rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6,BucketSizeDuration=10); 

%% connect UEs to initial gNBs
for u = 1:numsUE
    d = vecnorm(gNBPositions - UEs(u).Position, 2, 2);
    [~, gIdx] = min(d);
    connectUE(gNBs(gIdx), UEs(u), RLCBearerConfig=rlcBearerConfig);
end

%% probe RNTIs

probeStore = containers.Map('KeyType','double','ValueType','double');
probeL = addlistener(gNBs, 'PacketReceptionEnded', @(src,ev) probeRNTI(probeStore, ev));

%% add nodes to the simulation
addNodes(networkSimulator,gNBs);  
addNodes(networkSimulator,UEs);

%% configure channel model
channelConfig = struct("DelayProfile", "CDL-C", "DelaySpread", 100e-9);
channels = createCDLChannels(channelConfig, gNBs, UEs);
customChannelModel = hNRCustomChannelModel(channels,struct(PathlossMethod="nrPathloss"));
customChannelModel = hNRCustomChannelModel(channels, struct(PathlossMethod="nrPathloss"));
addChannelModel(networkSimulator, @(rxInfo, txData) ...
    buildingChannel(rxInfo, ...
        customChannelModel.applyChannelModel(rxInfo, txData), ...
        buildingsAABB, blockageDB));
%% configure UE mobility
enableMobility = true;
if enableMobility
    for u = 1:numsUE
        if UEs(u).Position(3) > 10   % aerial
            addMobility(UEs(u), SpeedRange=[30 50], ...
                BoundaryShape="rectangle", Bounds=[350 475 1500 1450]); %x center, y center, x width, y width
        else                          % terrestrial
            addMobility(UEs(u), SpeedRange=[1 5], ...
                BoundaryShape="rectangle", Bounds=[350 475 1500 1450]);
        end
    end
end

%% configure UE traffic
appDataRate = 1e3;
for ueIdx=1:numsUE 

    ulApps(ueIdx)=networkTrafficOnOff(GeneratePacket=true, OnTime=inf, OffTime=0, DataRate=appDataRate);
    addTrafficSource(UEs(ueIdx),ulApps(ueIdx)); 

    dlApps(ueIdx) = networkTrafficOnOff(GeneratePacket=true, OnTime=inf, OffTime=0, DataRate=appDataRate);
    addTrafficSource(gNBs(UEs(ueIdx).GNBNodeID),dlApps(ueIdx),DestinationNode=UEs(ueIdx));

end

%% setup visualiser
%networkVisualizer = helperNetworkVisualizer(SampleRate=5);
%addNodes(networkVisualizer,gNBs);
%addNodes(networkVisualizer,UEs);

%showBoundaries(networkVisualizer,gNBPositions,200);

%% configure handoverManager
% RNTI offset must be calibrated for each scenerio due to ID conflict bug in SLS Library
rntiOffset = -2;   

managers = cell(numsUE,1);
for u = 1:numsUE
    if UEs(u).Position(3) > 10
        lbl = 'aerial';
    else
        lbl = 'terrestrial';
    end
    rnti = UEs(u).ID + rntiOffset;
    managers{u} = handoverManager(UEs(u), gNBs, networkSimulator, ...
        ulApps(u), dlApps(u), 'eval', lbl, rnti);
end
%% position recorder for post-run replay
rec = positionRecorder([num2cell(gNBs), num2cell(UEs)], networkSimulator);
scheduleAction(networkSimulator, @rec.record, [], 1/rec.Rate, 1/rec.Rate);

%% RUN SIMULATION
simulationTime = 0.2;
wallStart = tic;

% Live progress
progressPeriod = simulationTime / 40;
prog = makeProgressReporter(networkSimulator, simulationTime, wallStart);
scheduleAction(networkSimulator, @(varargin) reportProgress(prog, varargin{:}), ...
    [], progressPeriod, progressPeriod);

run(networkSimulator, simulationTime);

elapsedWall = toc(wallStart);
fprintf('Done: sim %.2f s in %.1f s wall (%.1fx real-time)\n', ...
    simulationTime, elapsedWall, simulationTime / max(elapsedWall, eps));

%% network-side statistics from node objects
% Per-UE statistics struct (App / RLC / MAC / PHY substructures)
ueStats  = arrayfun(@(u) statistics(u), UEs);
gnbStats = arrayfun(@(g) statistics(g), gNBs);

S = cellfun(@(m) m.getHandoverStats(), managers);   % struct array, one per UE
allCounts = [S.count];
allRates  = [S.rate];
allPP     = [S.pingPongCount];

fprintf('\n=== Per-UE network statistics (%.1f s run) ===\n', simulationTime);
for u = 1:numsUE
    s = ueStats(u);

    % Application-layer throughput (operator-observable as user-plane volume)
    ulTxMbps = s.App.TransmittedBytes * 8 / simulationTime / 1e6;
    dlRxMbps = s.App.ReceivedBytes   * 8 / simulationTime / 1e6;

    % Traffic asymmetry ratio (UL-heavy is the FPV signature)
    asym = ulTxMbps / max(dlRxMbps, eps);

    % DL BLER proxy at the UE: PHY decode failures over received packets
    dlBLER = s.PHY.DecodeFailures / max(s.PHY.ReceivedPackets, 1);

    fprintf(['%-12s  UL %.3f Mbps | DL %.3f Mbps | UL/DL ratio %.2f | ' ...
        'DL BLER %.3f | HO Count %d | PP Count %d\n'], ...
        UEs(u).Name, ulTxMbps, dlRxMbps, asym, dlBLER, ...
        allCounts(u), allPP(u));
end

% UL decode failures live at the gNB side (receiver of the uplink)
fprintf('\n=== Per-gNB statistics ===\n');
for g = 1:numel(gNBs)
    sg = gnbStats(g);
    ulBLER = sg.PHY.DecodeFailures / max(sg.PHY.ReceivedPackets, 1);
    fprintf('%-8s  PHY rx %d | decode fails %d | UL BLER %.3f\n', ...
        gNBs(g).Name, sg.PHY.ReceivedPackets, sg.PHY.DecodeFailures, ulBLER);
end


%% print handover statistics at each time step 
% (Serving Cell, SINR, Visible Cells, Maximum Neighbour SINR, Mean
% Neighbour SINR, SINR Spread, Handover Count)
%managers = {h1, h2};
numMgrs  = numel(managers);

% Unpack handoverManager featureLog into named script-level variables.
% Column order must match featureNames in handoverManager.
feat = struct([]);
for k = 1:numMgrs
    fl = managers{k}.featureLog;
    feat(k).label = managers{k}.ueLabel;
    if isempty(fl)
        warning('No feature rows for %s (RNTI mismatch?)', managers{k}.UE.Name);
        [feat(k).time, feat(k).ueID, feat(k).isAerial, feat(k).servingGNB, ...
         feat(k).servingSINR, feat(k).numVisible, feat(k).maxNbrSINR, ...
         feat(k).meanNbrSINR, feat(k).sinrSpread, feat(k).hoCount, ...
         feat(k).timeSinceHO] = deal([]);
        continue;
    end
    feat(k).time         = fl(:,1);
    feat(k).ueID         = fl(:,2);
    feat(k).isAerial     = fl(:,3);
    feat(k).servingGNB   = fl(:,4);
    feat(k).servingSINR  = fl(:,5);
    feat(k).numVisible   = fl(:,6);
    feat(k).maxNbrSINR   = fl(:,7);
    feat(k).meanNbrSINR  = fl(:,8);
    feat(k).sinrSpread   = fl(:,9);
    feat(k).hoCount      = fl(:,10);
    feat(k).timeSinceHO  = fl(:,11);
end

% Table form of the same data, one table per UE, for inspection/export
%{
featNames = ["time","ueID","isAerial","servingGNB","servingSINR", ...
    "numVisible","maxNbrSINR","meanNbrSINR","sinrSpread","hoCount","timeSinceHO"];
featTables = cell(numMgrs,1);
for k = 1:numMgrs
    if isempty(managers{k}.featureLog)
        featTables{k} = table();
    else
        featTables{k} = array2table(managers{k}.featureLog, 'VariableNames', featNames);
    end
end
%}
figure('Name','Feature time series');

subplot(3,1,1); hold on;
for k = 1:numMgrs
    if isempty(feat(k).time), continue; end
    plot(feat(k).time, feat(k).servingSINR, 'DisplayName', feat(k).label);
end
ylabel('Serving SINR (dB)'); legend; title('Serving-cell SINR over time'); grid on;

subplot(3,1,2); hold on;
for k = 1:numMgrs
    if isempty(feat(k).time), continue; end
    plot(feat(k).time, feat(k).numVisible, 'DisplayName', feat(k).label);
end
ylabel('gNBs visible'); legend; title('Visible-gNB count over time'); grid on;

subplot(3,1,3); hold on;
for k = 1:numMgrs
    if isempty(feat(k).time), continue; end
    plot(feat(k).time, feat(k).sinrSpread, 'DisplayName', feat(k).label);
end
ylabel('SINR spread (dB)'); xlabel('Time (s)'); legend; title('SINR spread over time'); grid on;

%% 3D post-run replay
posLog = rec.toStruct();
replayScenario(posLog, gNBs, UEs, managers, buildingsAABB);

%% disply RNTI probe
%{
seenRNTIs = cell2mat(keys(probeStore))   % unique RNTIs observed
offsetRNTI = min(seenRNTIs) - min([UEs.ID])
counts    = cell2mat(values(probeStore)) % how often each appeared
delete(probeL);                          % detach the probe listener
%}
%% local functions
function channels = createCDLChannels(channelConfig,gNBs,UEs)
    numUEs = length(UEs);
    numNodes = length(gNBs) + numUEs;
    % Create channel matrix to hold the channel objects
    channels = cell(numNodes,numNodes);
    for i=1:length(gNBs)
        
        
        % Get the sample rate of waveform
        waveformInfo = nrOFDMInfo(gNBs(i).NumResourceBlocks,gNBs(i).SubcarrierSpacing/1e3);
        sampleRate = waveformInfo.SampleRate;
        
        
        for ueIdx = 1:numUEs
            % Configure the uplink channel model between gNB and UE
            channel = nrCDLChannel;
            channel.DelayProfile = channelConfig.DelayProfile;
            channel.DelaySpread = channelConfig.DelaySpread;
            channel.Seed = 73 + (ueIdx - 1);
            channel.CarrierFrequency = gNBs(i).CarrierFrequency;
            channel = hArrayGeometry(channel, UEs(ueIdx).NumTransmitAntennas,gNBs(i).NumReceiveAntennas,...
                "uplink");
            channel.SampleRate = sampleRate;
            channel.ChannelFiltering = false;
            channels{UEs(ueIdx).ID, gNBs(i).ID} = channel;
        
            % Configure the downlink channel model between gNB and UE
            channel = nrCDLChannel;
            channel.DelayProfile = channelConfig.DelayProfile;
            channel.DelaySpread = channelConfig.DelaySpread;
            channel.Seed = 73 + (ueIdx - 1);
            channel.CarrierFrequency = gNBs(i).CarrierFrequency;
            channel = hArrayGeometry(channel, gNBs(i).NumTransmitAntennas,UEs(ueIdx).NumReceiveAntennas,...
                "downlink");
            channel.SampleRate = sampleRate;
            channel.ChannelFiltering = false;
            channels{gNBs(i).ID, UEs(ueIdx).ID} = channel;
        end
    end
end
function probeRNTI(store, ev)
    if strcmp(ev.Data.SignalType, "SRS")
        r = ev.Data.RNTI;
        if isKey(store, r)
            store(r) = store(r) + 1;
        else
            store(r) = 1;
        end
    end
end

function p = makeProgressReporter(sim, totalSimTime, wallStart)
    p = struct('sim', sim, 'total', totalSimTime, 'wall', wallStart);
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
    fprintf('[%5.1f%%] sim %.3f/%.2f s | wall %.1f s | ETA %.1f s\n', ...
        100*frac, simNow, p.total, elapsedWall, eta);
end
function outData = buildingChannel(rxInfo, txData, buildingsAABB, blockageDB)
%buildingChannel Subtract blockageDB per building the LoS segment crosses.
%   Applied on top of whatever channel produced TXDATA (here, the CDL model).
%   buildingsAABB is N-by-6: [xmin xmax ymin ymax zmin zmax].
    outData = txData;
    if isempty(buildingsAABB), return; end
    p0 = txData.TransmitterPosition(:).';   % 1x3
    p1 = rxInfo.Position(:).';              % 1x3
    nBlocked = 0;
    for b = 1:size(buildingsAABB,1)
        if segmentIntersectsAABB(p0, p1, buildingsAABB(b,:))
            nBlocked = nBlocked + 1;
        end
    end
    if nBlocked > 0
        outData.Power = outData.Power - blockageDB * nBlocked;
    end
end

function tf = segmentIntersectsAABB(p0, p1, box)
%segmentIntersectsAABB Slab-method test, 3D segment vs axis-aligned box.
%   box = [xmin xmax ymin ymax zmin zmax]. True if the LoS p0->p1 passes
%   through the box (parameter t in [0,1]).
    d  = p1 - p0;
    lo = [box(1) box(3) box(5)];
    hi = [box(2) box(4) box(6)];
    tmin = 0; tmax = 1;
    for k = 1:3
        if abs(d(k)) < eps
            if p0(k) < lo(k) || p0(k) > hi(k), tf = false; return; end
        else
            t1 = (lo(k) - p0(k)) / d(k);
            t2 = (hi(k) - p0(k)) / d(k);
            if t1 > t2, tmp = t1; t1 = t2; t2 = tmp; end
            tmin = max(tmin, t1);
            tmax = min(tmax, t2);
            if tmin > tmax, tf = false; return; end
        end
    end
    tf = true;
end