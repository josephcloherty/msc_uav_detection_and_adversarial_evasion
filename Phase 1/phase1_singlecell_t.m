%% PHASE 1: Minimal single-cell 5G NR system-level simulation
%
% Purpose
%   First contact with the MATLAB 5G Toolbox system-level simulation (SLS)
%   workflow: one gNB serving four static UEs, abstracted PHY, mixed
%   traffic, statistics extraction at the end.
%
%   The point is to learn the object model and, more importantly for the
%   dissertation, to find out exactly WHERE the operator-observable
%   classifier features (CQI, throughput, traffic volume, BLER) live in
%   the statistics output. Later phases add mobility, multiple cells, and
%   the Fudan scaffold components (handover, per-gNB SRS measurement,
%   TR 36.777 aerial channel).
%
% Requirements
%   MATLAB R2026a, 5G Toolbox, Wireless Network Toolbox.
%   Uses abstracted PHY ("abstract-phy"), which is the R2026a default and
%   the fidelity level chosen for the project (run speed over PHY detail).
%
% References
%   MathWorks: "Overview of 5G System-Level Simulation",
%              "NR Cell Performance Evaluation with MIMO",
%              "NR Node Statistics".

%% 0. Clean state and reproducibility
% Every dataset-generating run in later phases must be reproducible, so
% the seeding habit starts here. Changing the seed changes channel
% realisations and traffic arrival times.
clear; close all;
rng(1);

%% 1. Initialise the wireless network simulator
% wirelessNetworkSimulator is a singleton-style discrete-event simulator.
% init clears any previous simulation state and returns the simulator
% object that all nodes are registered with. Always call init at the top
% of a script; stale state from a previous run otherwise leaks in.
networkSimulator = wirelessNetworkSimulator.init;

%% 2. Create the gNB
% nrGNB models a base station with a full RLC/MAC/PHY stack. All RF and
% numerology parameters are read-only after creation, so everything is
% set in the constructor.
%
% Parameter choices (kept deliberately ordinary for a first run):
%   Position          [x y z] in metres. z = 25 is a typical macro mast
%                     height. UE height relative to this matters from
%                     Phase 4 onward (aerial vs terrestrial).
%   CarrierFrequency  2.6 GHz, mid-band. Matches one of the bands the
%                     Fudan platform uses for its multi-band gNBs.
%   ChannelBandwidth  20 MHz, a modest, fast-to-simulate bandwidth.
%   SubcarrierSpacing 30 kHz (numerology mu = 1), the common mid-band
%                     choice. Slot duration = 0.5 ms.
%   DuplexMode        TDD, standard for mid-band NR.
%   TransmitPower     34 dBm total. Small-cell-ish; fine for a 500 m cell.
gnb = nrGNB( ...
    Name="gNB-1", ...
    Position=[0 0 25], ...
    CarrierFrequency=2.6e9, ...
    ChannelBandwidth=20e6, ...
    SubcarrierSpacing=30e3, ...
    DuplexMode="TDD", ...
    TransmitPower=34);

% Scheduler: round robin gives every UE equal scheduling opportunities,
% which makes per-UE statistics easy to interpret on a first run.
% (Alternatives: "PF", "BestCQI". Phase 5 may revisit this because the
% scheduler shapes the CQI/MCS and throughput features.)
configureScheduler(gnb, Scheduler="RoundRobin");

%% 3. Create the UEs
% One nrUE call with an N-by-3 Position matrix creates N UE objects.
% Note for R2026a: Name and most RF properties are settable ONLY at
% creation (older examples set ue.Name afterwards; that now errors).
%
% Layout: four static UEs at ground height (z = 1.5 m, handheld height)
% at increasing distance from the gNB, so the distance dependence of
% CQI/MCS/throughput is visible in the results:
%   UE-1   100 m   (near, expect high CQI)
%   UE-2   200 m
%   UE-3   350 m
%   UE-4   480 m   (cell edge for this power/band, expect low CQI)
uePositions = [ ...
    100   0  1.5;
    200   0  1.5;
    350   0  1.5;
    480   0  1.5];
ueNames = "UE-" + (1:size(uePositions,1));

ues = nrUE(Name=ueNames, Position=uePositions);

%% 3.5 Buildings: [xc yc width depth height], footprint centred at (xc,yc), base z=0
% x center, y center, x width, y width, height
buildingsRaw = [ ...
    150   0   40   60   30];     % building between gNB and the 200 m UE


% convert to axis-aligned min/max extents: [xmin xmax ymin ymax zmin zmax]
buildingsAABB = [ ...
    buildingsRaw(:,1)-buildingsRaw(:,3)/2, buildingsRaw(:,1)+buildingsRaw(:,3)/2, ...
    buildingsRaw(:,2)-buildingsRaw(:,4)/2, buildingsRaw(:,2)+buildingsRaw(:,4)/2, ...
    zeros(size(buildingsRaw,1),1),         buildingsRaw(:,5)];

blockageDB = 250;   % attenuation added per building the LoS segment crosses
addChannelModel(networkSimulator, ...
    @(rxInfo, txData) buildingChannel(rxInfo, txData, buildingsAABB, blockageDB));


%% 4. Connect UEs to the gNB
% connectUE performs RRC-style attachment: after this the UEs have an
% RNTI and ConnectionState "Connected". Connection events like this are
% themselves one of the classifier feature families (RRC/connection
% events), although in stock MATLAB they happen once at setup rather
% than as observable runtime signalling.
%
%   CSIReportPeriodicity  how often (ms) each UE reports CSI (CQI/PMI/RI)
%                         to the gNB. This IS the measurement-report
%                         mechanism the project's features come from, so
%                         it is worth knowing the knob exists. 10 ms is a
%                         reasonable default.
%
% FullBufferTraffic is NOT enabled here for all UEs. Full buffer means
% "infinite data always waiting", which maximises throughput but
% destroys any traffic-pattern information (volume, burstiness,
% asymmetry are all classifier features). Instead, explicit traffic
% models are attached in section 5, and full buffer is enabled for one
% UE only, as a contrast case.
connectUE(gnb, ues(1:3), CSIReportPeriodicity=10);

%% 5. Attach application traffic
% Traffic models live in Communications Toolbox (networkTraffic* objects)
% and are attached with addTrafficSource. Direction is set by WHERE the
% source is attached:
%   downlink: attach at the gNB with DestinationNode = the UE
%   uplink:   attach at the UE (destination defaults to its gNB)
%
% Mixed pattern across the four UEs so the per-UE traffic statistics
% differ visibly:
%
% UE-1: periodic On-Off DL traffic, always on => smooth, constant-rate.
%       DataRate in kb/s, packet size in bytes.
trafficUE1 = networkTrafficOnOff( ...
    OnTime=Inf, ...            % always on
    DataRate=5e3, ...          % 5 Mb/s
    PacketSize=1500, ...       % typical MTU-sized packets
    GeneratePacket=true);
addTrafficSource(gnb, trafficUE1, DestinationNode=ues(1));

% UE-2: bursty On-Off DL traffic => high burstiness at the same mean
%       load class. Exponentially distributed on/off periods.
trafficUE2 = networkTrafficOnOff( ...
    OnTime=0.05, ...           % mean on period (s)
    OffTime=0.15, ...          % mean off period (s)
    OnExponentialMean=0.05, ...
    OffExponentialMean=0.15, ...
    DataRate=20e3, ...         % 20 Mb/s while on
    PacketSize=1500, ...
    GeneratePacket=true);
addTrafficSource(gnb, trafficUE2, DestinationNode=ues(2));

% UE-3: uplink On-Off traffic only => strongly UL-asymmetric. A
%       video-streaming drone is UL-heavy, which is why traffic
%       asymmetry is on the project feature list. Attached at the UE,
%       so the direction is uplink.
trafficUE3 = networkTrafficOnOff( ...
    OnTime=Inf, ...
    DataRate=2e3, ...          % 2 Mb/s UL
    PacketSize=1500, ...
    GeneratePacket=true);
addTrafficSource(ues(3), trafficUE3);

% UE-4: full buffer in DL as the contrast case: the scheduler always has
%       data for it, so its throughput is limited only by channel
%       quality at 480 m. Useful to see what "link capacity" looks like
%       at the cell edge.
%connectUE(gnb, [], FullBufferTraffic="DL");% placeholder, see note below
% NOTE: FullBufferTraffic is a connectUE argument, so it must be set at
% connection time. The line above is illustrative only and does nothing
% (empty UE list). The clean way is to connect UE-4 separately:
% comment out section 4's single connectUE call and use:
%   connectUE(gnb, ues(1:3), CSIReportPeriodicity=10);
   connectUE(gnb, ues(4),   CSIReportPeriodicity=10, FullBufferTraffic="DL");
% It is left as an exercise so the connect/traffic relationship is
% learned by doing. As written, UE-4 simply carries no traffic, which is
% itself a valid data point (an idle UE).

%% 6. Register nodes with the simulator
% Nodes exist as objects but do not participate in the simulation until
% added. Order does not matter.
addNodes(networkSimulator, gnb);
addNodes(networkSimulator, ues);

% Channel model note: with no explicit channel configured, the simulator
% applies its default pathloss-based link model. Phase 3 introduces the
% 3GPP TR 38.901 statistical channel explicitly (and the intercell
% example shows the syntax). Phase 4 swaps in the TR 36.777 Urban Micro
% aerial overlay from the Fudan scaffold for aerial UEs. Keeping the
% default here keeps this first run simple and fast.

%% 7. Run the simulation
% Simulation time is wall-clock-expensive: every slot (0.5 ms at 30 kHz
% SCS) is an event cycle. 2 simulated seconds = 4000 slots, which runs
% in roughly a minute or two with abstracted PHY and 4 UEs. Long enough
% for the bursty traffic pattern on UE-2 to show several on/off cycles.
simulationTime = 2; % seconds
fprintf("Running %g s of simulated time...\n", simulationTime);
tic;
run(networkSimulator, simulationTime);
fprintf("Done in %.1f s wall-clock.\n", toc);
beep

%% 8. Extract statistics
% statistics(node) returns a struct with per-layer substructures:
%   .App  application layer: TransmittedPackets/Bytes, ReceivedPackets/
%         Bytes => per-UE traffic VOLUME and (DL vs UL) ASYMMETRY features
%   .RLC  radio link control counters
%   .MAC  grants, HARQ retransmissions, and per-UE CQI information
%         => CQI/MCS features
%   .PHY  transmissions, decode failures => BLER
%
% Exact field names vary slightly between releases; the loop below
% prints the whole struct for one UE so the R2026a layout can be
% inspected once, then pulls out the headline numbers for all UEs.
%
% THIS IS THE IMPORTANT PART FOR THE PROJECT: the Phase 5 feature
% extraction layer is essentially a structured, windowed version of what
% this section does crudely at end-of-run.

gnbStats = statistics(gnb);
ueStats  = arrayfun(@(u) statistics(u), ues);

% One-time inspection: dump the full statistics tree for UE-1 so the
% field layout under R2026a is on record (paste into deviations_log.md).
% fprintf("\n=== Full statistics struct, UE-1 (inspect once, then comment out) ===\n");
% disp(ueStats(1));

% Headline per-UE table. Field names below follow the documented R2024a+
% layout (NR Node Statistics doc page); if any field errors under
% R2026a, check the dumped struct above for the renamed field and record
% the change in the deviations log.
fprintf("%-6s %-8s %-8s %-14s\n", "UE", "DL MB/s", "UL MB/s", "Connection");
for k = 1:numel(ues)
    if k == 4
        % Full-buffer DL bypasses App layer, read from MAC
        dlBytes = ueStats(k).MAC.ReceivedBytes;
    else
        dlBytes = ueStats(k).App.ReceivedBytes;
    end
    ulBytes = ueStats(k).App.TransmittedBytes;
    
    dlThr = dlBytes * 8 / simulationTime / 1e6;
    ulThr = ulBytes * 8 / simulationTime / 1e6;
    fprintf("%-6s %-8.3f %-8.3f %-14s\n", ues(k).Name, dlThr, ulThr, ues(k).ConnectionState);
end

%% 9. What to look for in the output
% 1. UE-1 vs UE-2: similar-ish delivered volume but generated very
%    differently (constant vs bursty). At run-level totals they look
%    alike; only a windowed view separates them. This is the concrete
%    argument for windowed features in Phase 5.
% 2. UE-3: near-zero DL bytes, nonzero UL bytes => asymmetry feature.
% 3. UE-4: idle (or capacity-limited if the FullBufferTraffic exercise
%    in section 5 was done). Compare its MAC/PHY CQI-related fields with
%    UE-1's; distance should show up as lower CQI and more HARQ
%    retransmissions.
% 4. gnbStats: the gNB-side view. The project's observation model is
%    OPERATOR-side, so as a rule the features must be computable from
%    what the gNB sees (gnbStats and the gNB's knowledge of UE reports),
%    not from UE-internal state. Keep that discipline from the start.
%
%% 10. Suggested experiments before moving to Phase 2
% - Change rng seed: which numbers move? (Channel + traffic randomness.)
% - Halve ChannelBandwidth to 10 MHz: UE-4 throughput effect?
% - Set CSIReportPeriodicity=40: slower link adaptation => more HARQ
%   retransmissions after channel changes. Reporting periodicity is an
%   operator-controlled knob that shapes the feature stream.
% - Do the section 5 exercise (connect UE-4 with FullBufferTraffic="DL").
% - Then Phase 2: addMobility(ues(k), ...) with a constant-velocity or
%   random-waypoint model, and plot SINR/CQI against position over time.

%% 11. Plot 3D topology
figure('Name','Phase 1 topology','Color','w');
hold on; grid on; box on;

% Buildings
for b = 1:size(buildingsAABB,1)
    drawBox(buildingsAABB(b,:), [0.6 0.6 0.65]);
end

% gNB: triangle marker plus a dashed mast down to ground
gp = gnb.Position;
plot3(gp(1), gp(2), gp(3), '^', 'MarkerSize',12, ...
    'MarkerFaceColor',[0.85 0.20 0.20], 'MarkerEdgeColor','k');
plot3([gp(1) gp(1)], [gp(2) gp(2)], [0 gp(3)], 'k--');
text(gp(1), gp(2), gp(3)+8, gnb.Name, 'FontWeight','bold');

% UEs: coloured markers, height stem to ground, faint link to gNB
cols = lines(numel(ues));
for k = 1:numel(ues)
    p = ues(k).Position;
    plot3(p(1), p(2), p(3), 'o', 'MarkerSize',8, ...
        'MarkerFaceColor',cols(k,:), 'MarkerEdgeColor','k');
    plot3([p(1) p(1)], [p(2) p(2)], [0 p(3)], ':', 'Color',cols(k,:));        % height
    plot3([gp(1) p(1)], [gp(2) p(2)], [gp(3) p(3)], '-', 'Color',[0.7 0.7 0.7]); % link
    text(p(1), p(2), p(3)+8, ues(k).Name);
end

xlabel('x (m)'); ylabel('y (m)'); zlabel('height (m)');
title('Simulation topology'); view(35,25);
hold off;

%% Local Functions

function outData = buildingChannel(rxInfo, txData, buildings, blockageDB)
    outData = txData;
    p0 = txData.TransmitterPosition;   % live positions at transmit time
    p1 = rxInfo.Position;

    % baseline free-space path loss
    d      = norm(p1 - p0);
    lambda = physconst('LightSpeed') / txData.CenterFrequency;
    pl     = fspl(max(d,1), lambda);

    % geometric blockage: +blockageDB per building the LoS segment crosses
    for b = 1:size(buildings,1)
        lo = buildings(b, [1 3 5]);
        hi = buildings(b, [2 4 6]);
        if segmentIntersectsBox(p0, p1, lo, hi)
            pl = pl + blockageDB;
        end
    end

    outData.Power = outData.Power - pl;

    % REQUIRED: flat-channel metadata the NR receiver consumes.
    % Without these three fields, pushReceivedPacket errors.
    outData.Metadata.Channel.PathGains = ...
        permute(ones(outData.NumTransmitAntennas, rxInfo.NumReceiveAntennas), [3 4 1 2]) ...
        / sqrt(rxInfo.NumReceiveAntennas);
    outData.Metadata.Channel.PathFilters = 1;
    outData.Metadata.Channel.SampleTimes = 0;
end

function tf = segmentIntersectsBox(p0, p1, lo, hi)
% Does the segment p0->p1 intersect the axis-aligned box [lo, hi]?
d = p1 - p0;
tmin = 0; tmax = 1;          % parameter bounds along the segment
tf = false;
for i = 1:3
    if abs(d(i)) < 1e-9
        if p0(i) < lo(i) || p0(i) > hi(i)
            return            % parallel to this slab and outside it
        end
    else
        t1 = (lo(i) - p0(i)) / d(i);
        t2 = (hi(i) - p0(i)) / d(i);
        if t1 > t2, [t1, t2] = deal(t2, t1); end
        tmin = max(tmin, t1);
        tmax = min(tmax, t2);
        if tmin > tmax
            return            % slabs don't overlap: no intersection
        end
    end
end
tf = true;
end

function drawBox(aabb, col)
x = aabb(1:2); y = aabb(3:4); z = aabb(5:6);
[X,Y,Z] = ndgrid(x, y, z);
V = [X(:) Y(:) Z(:)];
F = [1 2 4 3; 5 6 8 7; 1 2 6 5; 3 4 8 7; 1 3 7 5; 2 4 8 6];
patch('Vertices',V,'Faces',F,'FaceColor',col, ...
    'FaceAlpha',0.25,'EdgeColor',[0.3 0.3 0.3]);
end