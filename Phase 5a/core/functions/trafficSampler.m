classdef trafficSampler < handle
% samples each UE's cumulative byte counters on a fixed period, giving the
% time series the windowed traffic features are computed from.

    properties
        samplePeriod = 0.1   % seconds
        UEs                  % nrUE array
        sim                  % simulator handle
        % per-UE rows of cumulative counters
        log
    end

    properties (Access = private)
        n                    % filled rows
    end

    methods
        function obj = trafficSampler(UEs, sim)
            obj.UEs = UEs;
            obj.sim = sim;
            obj.log = arrayfun(@(~) zeros(256, 5), 1:numel(UEs), ...
                'UniformOutput', false);
            obj.n = zeros(1, numel(UEs));
        end

        function sample(obj, ~, ~)
            t = obj.sim.CurrentTime;
            for u = 1:numel(obj.UEs)
                s = statistics(obj.UEs(u));
                row = [t, ...
                    getf(s, 'App', 'TransmittedBytes'), ...
                    getf(s, 'App', 'ReceivedBytes'), ...
                    getf(s, 'MAC', 'TransmittedBytes'), ...
                    getf(s, 'MAC', 'ReceivedBytes')];
                if obj.n(u) == size(obj.log{u}, 1)
                    obj.log{u} = [obj.log{u}; zeros(size(obj.log{u},1), 5)];
                end
                obj.n(u) = obj.n(u) + 1;
                obj.log{u}(obj.n(u), :) = row;
            end
        end

        function L = getLog(obj, u)
            % returns a trimmed copy of UE u's sample rows.
            L = obj.log{u}(1:obj.n(u), :);
        end
    end
end

function v = getf(s, layer, fld)
% reads a nested counter field, returning NaN when it is absent so a rename
% shows up as NaN columns rather than a crash.
    if isfield(s, layer) && isfield(s.(layer), fld)
        v = double(s.(layer).(fld));
    else
        v = NaN;
    end
end
