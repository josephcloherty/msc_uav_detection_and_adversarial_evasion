function rntiOffsetCalculator()
%rntiOffsetCalculator Find the correct cfg.rntiOffset for a scenario.
%
% Paste your gNB and UE geometry into the two blocks below (the same
% matrices you use in the scenario script) and press Run. The script
% rebuilds the network EXACTLY as phase3_Pipeline does (same SRS
% configuration and the same nearest-gNB attach order, which is what
% fixes the RNTI assignment), runs a 0.1 s probe simulation, listens to
% the SRS reception events, and reports:
%
%   - the RNTI each gNB actually assigns to each UE,
%   - whether the offset (RNTI - UE node ID) is the same for every UE at
%     every gNB (it must be, or the handover managers cannot filter their
%     own SRS events),
%   - the value to put in cfg.rntiOffset.
%
% The offset is probed empirically rather than computed from a formula
% because it originates in the toolbox's internal ID assignment (the "ID
% conflict bug" noted in the Phase 2 script) and depends on the number of
% nodes and the connection order. Probing the real assignment is correct
% by construction for any topology.
%
% Runtime: a 0.1 s simulation, typically a few seconds of wall time.
% Requires the core folder on the path (added below). Implemented as a
% function so the SRS listener can accumulate into the shared workspace;
% edit the paste-in block below and run:  rntiOffsetCalculator

clc;
addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'core'));

%% ---- PASTE YOUR SCENARIO GEOMETRY HERE -----------------------------------
gNBPositions = [ ...
    250  500  25;
    500  0    25;
        250  500  25;
    500  0    25;
        250  500  25;
    500  0    25;
        250  500  25;
    500  0    25;
    0    0    25];

uePositions = [ ...
    -6   100  1.5;
    -32  20   1.5;
    200  0    100;
        -6   100  1.5;
    -32  20   1.5;
    200  0    100;
        -6   100  1.5;
    -32  20   1.5;
    200  0    100;
        -6   100  1.5;
    -32  20   1.5;
    200  0    100;
    -50  130  120];

carrierFrequency = 2.6e9;      % match the scenario script
%% --------------------------------------------------------------------------

networkSimulator = wirelessNetworkSimulator.init;

% Forced to 1x1 (SISO) so the default free-space path loss channel can
% run. This probe only cares about connection order / RNTI assignment,
% not link fidelity, so the real scenario's antenna config doesn't
% matter here. Don't reuse this reduced setup for anything else.
gNBs = nrGNB(Name="gNB-" + (1:size(gNBPositions,1)), ...
    Position=gNBPositions, CarrierFrequency=carrierFrequency, ...
    ChannelBandwidth=20e6, SubcarrierSpacing=30e3, ...
    NumTransmitAntennas=1, NumReceiveAntennas=1, ReceiveGain=11, ...
    DuplexMode="TDD");
UEs = nrUE(Name="UE-" + (1:size(uePositions,1)), Position=uePositions, ...
    NumTransmitAntennas=1, NumReceiveAntennas=1, ReceiveGain=11);
numsUE = numel(UEs);

% Same connection sequence as phase3_Pipeline: SRS links first, then the
% nearest-gNB serving attach. The RNTI a gNB assigns depends on the order
% UEs connect to it, so this must mirror the pipeline exactly.
for i = 1:numsUE
    configureULforSRS(UEs(i), gNBs);
end
rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);
for u = 1:numsUE
    dist = vecnorm(gNBPositions - UEs(u).Position, 2, 2);
    [~, gIdx] = min(dist);
    connectUE(gNBs(gIdx), UEs(u), RLCBearerConfig=rlcBearerConfig);
end

addNodes(networkSimulator, gNBs);
addNodes(networkSimulator, UEs);

% Minimal traffic so uplink grants (and SRS) flow
for u = 1:numsUE
    app = networkTrafficOnOff(GeneratePacket=true, OnTime=inf, ...
        OffTime=0, DataRate=1e3);
    addTrafficSource(UEs(u), app);
end

% Probe: record every SRS reception as [gNB ID, RNTI]
seen = zeros(0, 2);
probeL = addlistener(gNBs, 'PacketReceptionEnded', ...
    @(src, ev) recordSRS(src, ev));
    function recordSRS(src, ev)
        if strcmp(ev.Data.SignalType, "SRS")
            seen(end+1, :) = [src.ID, ev.Data.RNTI]; %#ok<AGROW>
        end
    end

fprintf('Probing RNTI assignment (0.1 s simulation)...\n');
run(networkSimulator, 0.1);
delete(probeL);

%% ---- Analyse -------------------------------------------------------------
assert(~isempty(seen), ['No SRS events observed. Increase the probe ' ...
    'duration or check the SRS configuration.']);

ueIDs = sort([UEs.ID]);
fprintf('\nSRS RNTIs observed per gNB:\n');
consistent = true;
rntiSets = cell(numel(gNBs), 1);
for g = 1:numel(gNBs)
    r = unique(seen(seen(:,1) == gNBs(g).ID, 2)).';
    rntiSets{g} = r;
    fprintf('  gNB%-2d (ID %d): RNTIs [%s]\n', g, gNBs(g).ID, num2str(r));
    if numel(r) ~= numsUE
        warning(['gNB%d saw %d distinct RNTIs for %d UEs; probe longer ' ...
            'or check connectivity.'], gNBs(g).ID, numel(r), numsUE);
        consistent = false;
    end
end
for g = 2:numel(gNBs)
    if ~isequal(rntiSets{g}, rntiSets{1})
        consistent = false;
        warning(['RNTI sets differ between gNBs. A single rntiOffset ' ...
            'cannot serve this topology; the per-gNB assignment order ' ...
            'must be inspected.']);
    end
end

% Offset: RNTI - UE node ID, which must be one constant for all UEs.
% UEs connect to every gNB in index order 1..numsUE (configureULforSRS
% loop), so ascending RNTIs correspond to ascending UE IDs.
offsets = rntiSets{1} - ueIDs;
if consistent && all(offsets == offsets(1))
    fprintf('\nPer-UE mapping (gNB1 set):\n');
    for u = 1:numsUE
        fprintf('  %-6s node ID %d  ->  RNTI %d\n', ...
            UEs(u).Name, ueIDs(u), rntiSets{1}(u));
    end
    fprintf('\n==> cfg.rntiOffset = %d;\n', offsets(1));
else
    fprintf('\nOffsets per UE are NOT constant: [%s]\n', num2str(offsets));
    fprintf(['A single cfg.rntiOffset does not exist for this topology.\n' ...
        'Check that every UE connects to every gNB in the same order.\n']);
end
end
