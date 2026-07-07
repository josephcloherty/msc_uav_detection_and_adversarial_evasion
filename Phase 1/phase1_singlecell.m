%% PHASE 1: Minimal single-cell 5G NR system-level simulation

clear; close all;
rng(1);

%% 1. Initialise the wireless network simulator
networkSimulator = wirelessNetworkSimulator.init;

%% 2. Create the gNB
gnb = nrGNB( ...
    Name="gNB-1", ...
    Position=[0 0 25], ...
    CarrierFrequency=2.6e9, ...
    ChannelBandwidth=20e6, ...
    SubcarrierSpacing=30e3, ...
    DuplexMode="TDD", ...
    TransmitPower=34);

configureScheduler(gnb, Scheduler="BestCQI");

%% 3. Create the UEs

uePositions = [ ...
    100   0  1.5;
    200   0  1.5;
    350   0  1.5;
    480   0  1.5];
ueNames = "UE-" + (1:size(uePositions,1));

ues = nrUE(Name=ueNames, Position=uePositions);

%% 3.5 Buildings: x center, y center, x width, y width, height
buildingsRaw = [ ...
    150   0   40   60   30];     % building between gNB and the 200 m UE


% convert to axis-aligned min/max extents: [xmin xmax ymin ymax zmin zmax]
buildingsAABB = [ ...
    buildingsRaw(:,1)-buildingsRaw(:,3)/2, buildingsRaw(:,1)+buildingsRaw(:,3)/2, ...
    buildingsRaw(:,2)-buildingsRaw(:,4)/2, buildingsRaw(:,2)+buildingsRaw(:,4)/2, ...
    zeros(size(buildingsRaw,1),1),         buildingsRaw(:,5)];

blockageDB = 50;   % attenuation added per building the LoS segment crosses
%addChannelModel(networkSimulator, ...
%    @(rxInfo, txData) buildingChannel(rxInfo, txData, buildingsAABB, blockageDB));


%% 4. Connect UEs to the gNB
connectUE(gnb, ues(1:3), CSIReportPeriodicity=10);

%% 5. Attach application traffic

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
%       asymmetry is on the candidate feature list. Attached at the UE,
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
%       at the cell edge. FullBufferTraffic is a connectUE argument, so it 
%       must be set at connection time

   connectUE(gnb, ues(4),   CSIReportPeriodicity=10, FullBufferTraffic="DL");

%% 6. Register nodes with the simulator
addNodes(networkSimulator, gnb);
addNodes(networkSimulator, ues);


%% 7. Run the simulation

simulationTime = 2; % seconds
fprintf("Running %g s of simulated time...\n", simulationTime);
tic;
run(networkSimulator, simulationTime);
fprintf("Done in %.1f s wall-clock.\n", toc);
beep

%% 8. Extract statistics

gnbStats = statistics(gnb);
ueStats  = arrayfun(@(u) statistics(u), ues);

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

%% 9. Plot 3D topology
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

    % flat-channel metadata the NR receiver consumes.
    % Without these three fields, pushReceivedPacket errors.
    outData.Metadata.Channel.PathGains = ...
        permute(ones(outData.NumTransmitAntennas, rxInfo.NumReceiveAntennas), [3 4 1 2]) ...
        / sqrt(rxInfo.NumReceiveAntennas);
    outData.Metadata.Channel.PathFilters = 1;
    outData.Metadata.Channel.SampleTimes = 0;
end

function tf = segmentIntersectsBox(p0, p1, lo, hi)
% Does the segment p0->p1 intersect the axis-aligned box?
d = p1 - p0;
tmin = 0; tmax = 1;          
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