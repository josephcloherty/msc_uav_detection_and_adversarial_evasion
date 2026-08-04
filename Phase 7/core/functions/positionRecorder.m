classdef positionRecorder < handle
    %positionRecorder Logs node positions over time for post-run replay.
    %   A handle class, so the scheduled record() callback accumulates into
    %   one object.
    %
    %   Wire it up before run():
    %       rec = positionRecorder([num2cell(gNBs), num2cell(UEs)], networkSimulator);
    %       scheduleAction(networkSimulator, @rec.record, [], 1/rec.Rate, 1/rec.Rate);
    %
    %   Afterwards rec.toStruct() gives the posLog replayScenario wants.

    properties
        AllNodes        % cell array of node objects (gNBs first, then UEs)
        NodeIDs         % vector of node IDs, aligned with AllNodes
        Simulator       % handle to the wirelessNetworkSimulator
        Rate = 100;     % snapshots per second (Hz)
        Times = [];     % 1 x T vector of timestamps (s)
        XYZ = [];       % N x 3 x T array of positions
    end

    methods
        function obj = positionRecorder(allNodes, simulator)
            obj.AllNodes = allNodes;
            obj.NodeIDs = cellfun(@(n) n.ID, allNodes);
            obj.Simulator = simulator;
        end

        function record(obj, varargin)
            %record Snapshot all node positions at the current sim time.
            %   Extra args are ignored, to match the scheduleAction contract.
            t = obj.Simulator.CurrentTime;
            N = numel(obj.AllNodes);
            frame = zeros(N, 3);
            for n = 1:N
                frame(n, :) = obj.AllNodes{n}.Position;
            end
            obj.Times(end+1) = t;
            % XYZ(:,:,end+1) on an empty XYZ would leave a spurious
            % all-zero first frame, because size([],3) is 1.
            if isempty(obj.XYZ)
                obj.XYZ = frame;
            else
                obj.XYZ(:, :, end+1) = frame;
            end
        end

        function posLog = toStruct(obj)
            %toStruct Return a plain struct for replayScenario.
            posLog = struct( ...
                'times',   obj.Times, ...
                'xyz',     obj.XYZ, ...
                'nodeIDs', obj.NodeIDs, ...
                'rate',    obj.Rate);
        end
    end
end
