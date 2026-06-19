%% PHASE 2: Basic network on the Fudan framework, with handover
%
% Purpose
%   First working scenario built INSIDE the Fudan class framework rather
%   than from stock MATLAB objects. It stands up a multi-gNB network, one
%   moving UE, the CDL channel wrapper, and the handoverManager running
%   the A3 policy. The point is to confirm the framework runs end to end
%   on R2026a and to see handover events fire, before adding the
%   aerial-vs-terrestrial classification work in later phases.
%
%   This is deliberately modelled on baseNetwork.m from the repo (the
%   minimal "no socket" entry point), stripped to the essentials and
%   commented so the construction order is clear. The transport-protocol
%   scripts (tcp_matlab.m, quic_matlab.m) add a socket layer on top of
%   this same skeleton; that layer is NOT needed for the classifier work
%   and is left out here.
%
% Prerequisites (do these once, see notes at the bottom)
%   1. hArrayGeometry.m must be on the path. It ships with the MathWorks
%      example "NRCellPerformanceEvaluationWithMIMOExample", NOT with the
%      Fudan repo. createCDLChannels (copied in below) calls it.
%   2. handoverManager.m, helperNetworkVisualizer.m, and
%      hNRCustomChannelModel.m must be on the path (they are in the repo).
%
% Requirements
%   MATLAB R2026a, 5G Toolbox, Wireless Network Toolbox.
%   The repo targets R2024b; expect deprecation warnings on R2026a and
%   record each one in deviations_log.md.

%% 0. Clean state and reproducibility
clear; close all; clc;
rng("default");   % the repo uses rng("default"); keep it identical so
                  % behaviour matches the repo's own runs while learning.

%% 1. Initialise the simulator
networkSimulator = wirelessNetworkSimulator.init;

%% 2. Create the gNBs
% Five gNBs in the same layout the repo uses in baseNetwork.m. The
% antenna and gain settings are copied from the repo because
% createCDLChannels and the SINR measurement path assume these multi-
% antenna configurations; changing them affects the channel geometry, so
% leave them as-is for a first run.
%
%   NumTransmitAntennas=16, NumReceiveAntennas=8 at the gNB
%   ReceiveGain=11 dB, TDD, 2.6 GHz, 20 MHz, 30 kHz SCS
gNBPositions = [   0    0  25;
                 350    0  25;
                 700    0  25;
                 180  300  25;
                 550  300  25];
gNBNames = "gNB-" + (1:size(gNBPositions,1));
gNBs = nrGNB( ...
    Name=gNBNames, ...
    Position=gNBPositions, ...
    CarrierFrequency=2.6e9, ...
    ChannelBandwidth=20e6, ...
    SubcarrierSpacing=30e3, ...
    NumTransmitAntennas=16, ...
    NumReceiveAntennas=8, ...
    ReceiveGain=11, ...
    DuplexMode="TDD");

%% 3. Create the UE
% One UE to start with. Position and antenna config follow the repo.
% z = 100 m places it at aerial altitude; this is the "UAV" case. In
% Phase 3 a second UE at ground height (z ~ 1.5 m) is added as the
% terrestrial contrast, but one UE is enough to confirm handover works.
uePositions = [-100 100 100];
ueNames = "UE-" + (1:size(uePositions,1));
UEs = nrUE( ...
    Name=ueNames, ...
    Position=uePositions, ...
    NumTransmitAntennas=4, ...
    NumReceiveAntennas=2, ...
    ReceiveGain=11);
numUE = numel(UEs);

%% 4. Configure uplink SRS toward ALL gNBs
% This is the key step that makes operator-side per-gNB measurement
% possible. configureULforSRS sets the UE to transmit Sounding Reference
% Signals that every gNB in the array can receive, so each gNB can
% estimate that UE's uplink SINR even when it is not the serving cell.
%
% The handoverManager listens for these SRS receptions
% (PacketReceptionEnded events with SignalType "SRS") and builds the
% per-gNB SINR matrix from them. Without this call there is no
% neighbour-cell measurement and the A3 policy has nothing to compare.
%
% NOTE on the >16 UEs per gNB SRS constraint: with many UEs the SRS
% periodicity needs manual adjustment or measurements collide. With one
% UE this is not a concern yet.
for i = 1:numUE
    configureULforSRS(UEs(i), gNBs);
end

%% 5. Connect the UE to its initial serving gNB
% The repo uses a custom RLC bearer config; copy it so RLC behaviour
% matches. The UE starts attached to gNB-1; the handover manager will
% move it to better cells as it flies.
rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);
connectUE(gNBs(1), UEs(1), RLCBearerConfig=rlcBearerConfig);

%% 6. Register nodes with the simulator
addNodes(networkSimulator, gNBs);
addNodes(networkSimulator, UEs);

%% 7. Create and attach the channel model
% createCDLChannels (defined at the bottom, copied from the repo) builds
% a CDL-C channel for every gNB-UE link, in both directions. It calls
% hArrayGeometry, which must be on the path (see prerequisites).
%
% hNRCustomChannelModel wraps those per-link channels and applies them
% during the run. IMPORTANT: this wrapper is the stock MathWorks class
% and uses a UMa (urban macro) pathloss scenario, NOT the TR 36.777
% aerial overlay described in the Fudan paper. The aerial channel is a
% Phase 3 task; for now every UE, including the one at 100 m, uses the
% ground-oriented model. Flag this in the methodology notes.
channelConfig = struct("DelayProfile", "CDL-C", "DelaySpread", 100e-9);
channels = createCDLChannels(channelConfig, gNBs, UEs);
customChannelModel = hNRCustomChannelModel(channels, struct(PathlossMethod="nrPathloss"));
addChannelModel(networkSimulator, @customChannelModel.applyChannelModel);

%% 8. Add mobility to the UE
% A moving UE is what makes handovers happen. Random waypoint within a
% rectangular boundary, matching the repo's mobility block.
%
% NOTE: the repo's SpeedRange comment says "10-15 m/s" but the value is
% [1000 1500]. Treat that as a units quirk to check against the repo's
% intent; for a first run a clearly sane speed is used here instead.
% Record whichever interpretation is correct in the deviations log.
ueSpeedRange = [10 15];                 % m/s, low-altitude UAV speeds
addMobility(UEs, ...
    SpeedRange=ueSpeedRange, ...
    BoundaryShape="rectangle", ...
    Bounds=[300 150 1000 700]);         % [x y width height], from repo

%% 9. Traffic configuration
% Always-on uplink and downlink On-Off traffic per UE, matching the repo.
% Uplink is attached at the UE; downlink is attached at the UE's CURRENT
% serving gNB (UEs(ueIdx).GNBNodeID tells you which one). The handover
% manager re-attaches these flows after each handover via resetTraffic,
% which is why the app handles are passed into the manager in section 11.
appDataRate = 1e3;                       % kbps
ulApps = networkTrafficOnOff.empty(0, numUE);
dlApps = networkTrafficOnOff.empty(0, numUE);
for ueIdx = 1:numUE
    ulApps(ueIdx) = networkTrafficOnOff( ...
        GeneratePacket=true, OnTime=inf, OffTime=0, DataRate=appDataRate);
    addTrafficSource(UEs(ueIdx), ulApps(ueIdx));

    dlApps(ueIdx) = networkTrafficOnOff( ...
        GeneratePacket=true, OnTime=inf, OffTime=0, DataRate=appDataRate);
    addTrafficSource(gNBs(UEs(ueIdx).GNBNodeID), dlApps(ueIdx), ...
        DestinationNode=UEs(ueIdx));
end

%% 10. Network visualiser (optional but useful)
% Shows gNB positions, the UE, and coverage boundaries while the sim
% runs. Comment out for faster batch runs later.
networkVisualizer = helperNetworkVisualizer(SampleRate=100);
addNodes(networkVisualizer, gNBs);
addNodes(networkVisualizer, UEs);
showBoundaries(networkVisualizer, gNBPositions, 200);

%% 11. Attach the handover manager
% This is the core of the framework. The constructor signature is:
%   handoverManager(UE, gNBs, networkSimulator, ulApp, dlApp, mode)
%
% What it does internally:
%   - registers a listener on the gNBs' PacketReceptionEnded event to
%     collect per-gNB uplink SINR from this UE's SRS (handlePacketReception)
%   - schedules checkHandoverPolicy to run every scanPeriod (0.01 s),
%     starting at scanStartTime (0.0795 s, once enough SRS updates exist
%     to average)
%   - runs the A3 policy by default (handoverPolicy{1} = a3Condition):
%     hand over to a neighbour gNB whose averaged SINR exceeds the
%     serving gNB's by more than hysteresis (1 dB)
%   - on a trigger, executeHandover disconnects the source, reconnects
%     the target, and resets the traffic flows
%
% Mode 'eval' avoids the Python RL hooks (DQN/DDPG call into py.*),
% which need an external Python setup. A3 is pure MATLAB, so 'eval' with
% the default A3 policy runs standalone. Use 'eval' here, NOT 'train'.
%
% IMPORTANT detail in handlePacketReception: it matches SRS to this UE
% with the test  event.Data.RNTI == obj.UE.ID - 5. That "- 5" assumes a
% specific ID offset between UE IDs and RNTIs that holds for the repo's
% node counts (5 gNBs => UE IDs start at 6, RNTI 1 => UE ID 6). If you
% change the number of gNBs, this offset breaks and SINR will silently
% never be collected. With 5 gNBs as here, it is correct. Note it for
% when you scale the topology in Phase 5.
h1 = handoverManager(UEs(1), gNBs, networkSimulator, ulApps(1), dlApps(1), 'eval');

%% 12. Run
% Start with a short run to confirm everything executes. The handover
% manager's averaging needs the first ~0.08 s of SRS before it acts, so
% the run must be at least a few tenths of a second to see anything; a
% few seconds to see actual handovers as the UE moves between cells.
simulationTime = 2;   % seconds; raise to 8-10 s to see multiple handovers
fprintf("Running %g s...\n", simulationTime);
run(networkSimulator, simulationTime);

%% 13. Inspect results
% The handover manager accumulates everything you care about as it runs.
fprintf("\nHandovers performed: %d\n", h1.handover_num);

% Per-gNB uplink SINR matrix: rows = gNB ID, columns = measurement index.
% This IS the neighbour-cell SINR feature substrate for the classifier.
fprintf("SINR matrix size [gNB x samples]: %s\n", mat2str(size(h1.ulSINR)));

% SINR of whichever cell was serving at each decision step. A UAV flying
% across cells shows this dipping and recovering as it approaches cell
% edges, which is part of the aerial mobility signature.
if ~isempty(h1.connectedulSINR)
    figure;
    plot(h1.connectedulSINR);
    xlabel("Measurement index");
    ylabel("Serving-cell uplink SINR (dB)");
    title("Serving-cell SINR over the flight");
    grid on;
end

% Quick look at the final averaged per-gNB SINR (last decision step).
if ~isempty(h1.ulSINRAverage)
    fprintf("\nFinal averaged SINR per gNB (dB):\n");
    for g = 1:numel(gNBs)
        fprintf("  %-7s %.2f\n", gNBs(g).Name, h1.ulSINRAverage(g));
    end
end

%% 14. What to check, and what comes next
% Check:
%  - Console prints "Handover executed: UE.. from gNB.. to gNB.." as the
%    UE moves. If you see zero handovers in a 2 s run, raise
%    simulationTime to 8-10 s; the UE may not have reached a cell edge.
%  - h1.ulSINR should be non-empty. If it is all zeros/empty, the SRS
%    RNTI offset (UE.ID - 5) is wrong for your node count, or SRS was not
%    configured (section 4).
%  - The serving-cell SINR plot should show variation as the UE flies.
%
% Next (Phase 3):
%  - Add a second, terrestrial UE at z ~ 1.5 m with its own
%    handoverManager, and compare handover counts and SINR profiles
%    against this aerial UE.
%  - Replace the UMa pathloss in hNRCustomChannelModel with the TR 36.777
%    Urban-Micro aerial overlay for the aerial UE only.
%  - Start logging the per-gNB SINR matrix (h1.ulSINR) into a windowed
%    feature table, which becomes the classifier dataset.

%% ----------------------------------------------------------------------
%% Local function: createCDLChannels (copied verbatim from baseNetwork.m)
%% Builds a CDL channel object for every gNB<->UE link in both directions.
%% Requires hArrayGeometry on the path.
%% ----------------------------------------------------------------------
function channels = createCDLChannels(channelConfig, gNBs, UEs)
    numUEs = length(UEs);
    numNodes = length(gNBs) + numUEs;
    channels = cell(numNodes, numNodes);
    for i = 1:length(gNBs)
        waveformInfo = nrOFDMInfo(gNBs(i).NumResourceBlocks, gNBs(i).SubcarrierSpacing/1e3);
        sampleRate = waveformInfo.SampleRate;
        for ueIdx = 1:numUEs
            % Uplink channel (UE -> gNB)
            channel = nrCDLChannel;
            channel.DelayProfile = channelConfig.DelayProfile;
            channel.DelaySpread = channelConfig.DelaySpread;
            channel.Seed = 73 + (ueIdx - 1);
            channel.CarrierFrequency = gNBs(i).CarrierFrequency;
            channel = hArrayGeometry(channel, UEs(ueIdx).NumTransmitAntennas, gNBs(i).NumReceiveAntennas, "uplink");
            channel.SampleRate = sampleRate;
            channel.ChannelFiltering = false;
            channels{UEs(ueIdx).ID, gNBs(i).ID} = channel;

            % Downlink channel (gNB -> UE)
            channel = nrCDLChannel;
            channel.DelayProfile = channelConfig.DelayProfile;
            channel.DelaySpread = channelConfig.DelaySpread;
            channel.Seed = 73 + (ueIdx - 1);
            channel.CarrierFrequency = gNBs(i).CarrierFrequency;
            channel = hArrayGeometry(channel, gNBs(i).NumTransmitAntennas, UEs(ueIdx).NumReceiveAntennas, "downlink");
            channel.SampleRate = sampleRate;
            channel.ChannelFiltering = false;
            channels{gNBs(i).ID, UEs(ueIdx).ID} = channel;
        end
    end
end