classdef positionRecorder < handle
    %positionRecorder Logs node positions over time for post-run replay.
    %   Handle class so that the record() callback, invoked by
    %   wirelessNetworkSimulator.scheduleAction, accumulates into the same
    %   object rather than a value copy. Designed to be driven from a script.
    %
    %   Usage (in baseNetwork.m, BEFORE run):
    %       rec = positionRecorder([num2cell(gNBs), num2cell(UEs)], networkSimulator);
    %       scheduleAction(networkSimulator, @rec.record, [], 1/rec.Rate, 1/rec.Rate);
    %   After run, rec.Times and rec.XYZ hold the history, and
    %   rec.toStruct() returns the posLog struct expected by replayScenario.

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
            % allNodes: cell array of node objects. simulator: sim handle.
            obj.AllNodes = allNodes;
            obj.NodeIDs = cellfun(@(n) n.ID, allNodes);
            obj.Simulator = simulator;
        end

        function record(obj, varargin)
            %record Snapshot all node positions at the current sim time.
            %   Signature matches the scheduleAction callback contract
            %   (extra args ignored).
            t = obj.Simulator.CurrentTime;
            N = numel(obj.AllNodes);
            frame = zeros(N, 3);
            for n = 1:N
                frame(n, :) = obj.AllNodes{n}.Position;
            end
            obj.Times(end+1) = t;
            obj.XYZ(:, :, end+1) = frame;
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
