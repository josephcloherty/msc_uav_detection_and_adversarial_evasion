% no handover no socket

%% network
rng("default") % Reset the random number generator
%numFrameSimulation = 10; % Simulation time in terms of number of 10 ms frames
networkSimulator = wirelessNetworkSimulator.init;

% nrNode
gNBPositions = [0 0 25; 350 0 25;700 0 25;180 300 25; 550 300 25 ];      
gNBNames = "gNB-" + (1:size(gNBPositions,1));
gNBs = nrGNB(Name=gNBNames,Position=gNBPositions,CarrierFrequency=2.6e9,ChannelBandwidth=20e6,SubcarrierSpacing=30e3,...
    NumTransmitAntennas=16,NumReceiveAntennas=8,ReceiveGain=11,DuplexMode="TDD");


uePositions =[-100 100 1.5;400 0 60]; %650 300 
UENames = "UE-" + (1:size(uePositions,1));
UEs= nrUE(Name=UENames,Position=uePositions,NumTransmitAntennas=4,NumReceiveAntennas=2,ReceiveGain=11);
numsUE=length(UEs);

for i=1:numsUE
    configureULforSRS(UEs(i),gNBs);
end

rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6,BucketSizeDuration=10); 
% first connect
connectUE(gNBs(1),UEs(1),RLCBearerConfig=rlcBearerConfig);
connectUE(gNBs(2),UEs(2),RLCBearerConfig=rlcBearerConfig);


%
addNodes(networkSimulator,gNBs);  
addNodes(networkSimulator,UEs)    
%channel

channelConfig = struct("DelayProfile", "CDL-C", "DelaySpread", 100e-9);
channels = createCDLChannels(channelConfig, gNBs, UEs);
customChannelModel = hNRCustomChannelModel(channels,struct(PathlossMethod="nrPathloss"));
addChannelModel(networkSimulator, @customChannelModel.applyChannelModel);


enableMobility = true;
if enableMobility
    % Terrestrial UE: slow, ground-plane bounds
    addMobility(UEs(1), SpeedRange=[1 5], ...
        BoundaryShape="rectangle", Bounds=[300 150 1000 700]);

    % Aerial UE (drone): faster, different bounds
    addMobility(UEs(2), SpeedRange=[20 40], ...
        BoundaryShape="rectangle", Bounds=[0 0 1400 700]);
end

%% Traffic Configuration

appDataRate = 1e3; % Application data rate in kilo bits per second (kbps) 
for ueIdx=1:numsUE 
    ulApps(ueIdx)=networkTrafficOnOff(GeneratePacket=true, OnTime=inf, OffTime=0, DataRate=appDataRate);
    addTrafficSource(UEs(ueIdx),ulApps(ueIdx)); 
    dlApps(ueIdx) = networkTrafficOnOff(GeneratePacket=true, OnTime=inf, OffTime=0, DataRate=appDataRate);
    addTrafficSource(gNBs(UEs(ueIdx).GNBNodeID),dlApps(ueIdx),DestinationNode=UEs(ueIdx));
end



%% network topology
networkVisualizer = helperNetworkVisualizer(SampleRate=100); % Sample rate indicates the visualization refresh rate in Hertz
addNodes(networkVisualizer,gNBs);
addNodes(networkVisualizer,UEs);

showBoundaries(networkVisualizer,gNBPositions,200);%圆形


%% Mobility management with feature logging
% Labels are ground truth from the scenario: UEs(1) terrestrial, UEs(2) aerial.
rnti1 = UEs(1).ID - 2;   % = 4
rnti2 = UEs(2).ID - 2;   % = 5

h1 = handoverManager(UEs(1), gNBs, networkSimulator, ulApps(1), dlApps(1), 'train', 'terrestrial', rnti1);
h2 = handoverManager(UEs(2), gNBs, networkSimulator, ulApps(2), dlApps(2), 'train', 'aerial', rnti2);

% Position recorder for post-run replay
rec = positionRecorder([num2cell(gNBs), num2cell(UEs)], networkSimulator);
scheduleAction(networkSimulator, @rec.record, [], 1/rec.Rate, 1/rec.Rate);

%% run
run(networkSimulator,1);

%% Post-run feature reporting
managers = {h1, h2};
allRows = [];
for k = 1:numel(managers)
    m = managers{k};
    if ~isempty(m.featureLog)
        allRows = [allRows; m.featureLog];
    end
end

if isempty(allRows)
    disp('No feature rows logged. Increase run duration or check scanStartTime.');
else
    % Assemble a labelled feature table (long format, one row per UE per scan)
    featTable = array2table(allRows, 'VariableNames', h1.featureNames);
    featTable.label = repmat("", height(featTable), 1);
    featTable.label(featTable.label_is_aerial==1) = "aerial";
    featTable.label(featTable.label_is_aerial==0) = "terrestrial";

    fprintf('\n=== Feature table: %d rows ===\n', height(featTable));
    disp(featTable(1:min(10,height(featTable)), :));   % preview first 10
    fprintf('... (%d total rows)\n', height(featTable));

    % Per-class summary
    fprintf('\nPer-class mean features:\n');
    summary = groupsummary(featTable, 'label', 'mean', ...
        {'servingSINR','numVisible','maxNeighbourSINR','sinrSpread','handoverCount'});
    disp(summary);

    % --- Optional CSV (uncomment to write) ---
    % writetable(featTable, 'features.csv');
    % fprintf('Wrote features.csv\n');

    % --- Static plots ---
    figure('Name','Feature time series');
    subplot(3,1,1); hold on;
    for k = 1:numel(managers)
        m = managers{k};
        if isempty(m.featureLog), continue; end
        plot(m.featureLog(:,1), m.featureLog(:,5), 'DisplayName', m.ueLabel); % servingSINR
    end
    ylabel('Serving SINR (dB)'); legend; title('Serving-cell SINR over time'); grid on;

    subplot(3,1,2); hold on;
    for k = 1:numel(managers)
        m = managers{k};
        if isempty(m.featureLog), continue; end
        plot(m.featureLog(:,1), m.featureLog(:,6), 'DisplayName', m.ueLabel); % numVisible
    end
    ylabel('gNBs visible'); legend; title('Visible-gNB count over time'); grid on;

    subplot(3,1,3); hold on;
    for k = 1:numel(managers)
        m = managers{k};
        if isempty(m.featureLog), continue; end
        plot(m.featureLog(:,1), m.featureLog(:,9), 'DisplayName', m.ueLabel); % sinrSpread
    end
    ylabel('SINR spread (dB)'); xlabel('Time (s)'); legend; title('SINR spread over time'); grid on;
end

% Scrollable 3D replay
posLog = rec.toStruct();
replayScenario(posLog, gNBs, UEs, {h1, h2});
function channels = createCDLChannels(channelConfig,gNBs,UEs)

%createCDLChannels Create channels between gNBs and UEs in a cell
%   CHANNELS = createCDLChannels(CHANNELCONFIG,GNB,UES) creates channels
%   between GNB and UES in a cell.
%
%   CHANNELS is a N-by-N array where N is the number of nodes in the cell.
%
%   CHANNLECONFIG is a struct with these fields - DelayProfile and
%   DelaySpread.
%
%   GNB is an array of nrGNB object.
%
%   UES is an array of nrUE objects.

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


