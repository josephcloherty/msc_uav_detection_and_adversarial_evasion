classdef positionRecorder < handle
    % logs node positions over time so a run can be replayed afterwards.
    % handle class, so the record() callback accumulates into the same object.

    properties
        AllNodes        % node objects
        NodeIDs         % node ids
        Simulator       % simulator handle
        Rate = 100;     % snapshots per second
        Times = [];     % timestamps
        XYZ = [];       % positions
    end

    methods
        function obj = positionRecorder(allNodes, simulator)
            % store nodes and ids
            obj.AllNodes = allNodes;
            obj.NodeIDs = cellfun(@(n) n.ID, allNodes);
            obj.Simulator = simulator;
        end

        function record(obj, varargin)
            % snapshots all node positions at the current sim time.
            t = obj.Simulator.CurrentTime;
            N = numel(obj.AllNodes);
            frame = zeros(N, 3);
            for n = 1:N
                frame(n, :) = obj.AllNodes{n}.Position;
            end
            obj.Times(end+1) = t;
            % size([],3) is 1, so guard the first append
            if isempty(obj.XYZ)
                obj.XYZ = frame;
            else
                obj.XYZ(:, :, end+1) = frame;
            end
        end

        function posLog = toStruct(obj)
            % returns a plain struct for replayScenario.
            posLog = struct( ...
                'times',   obj.Times, ...
                'xyz',     obj.XYZ, ...
                'nodeIDs', obj.NodeIDs, ...
                'rate',    obj.Rate);
        end
    end
end
