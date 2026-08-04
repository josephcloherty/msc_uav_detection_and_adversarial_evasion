classdef trafficSampler < handle
%trafficSampler Periodic per-UE traffic byte sampling.
%
%   Samples each UE's cumulative byte counters every samplePeriod seconds,
%   which is what the windowed traffic features are computed from.
%   End-of-run totals cannot serve here, since burstiness needs the
%   within-window increments and constant and bursty sources look identical
%   at run level.
%
%   The features use the MAC counters, which are the bytes that cross the
%   radio interface and so what an operator meters. App counters are logged
%   for diagnostics only.
%
%   Wiring:
%       sampler = trafficSampler(UEs, networkSimulator);
%       scheduleAction(networkSimulator, @sampler.sample, [], ...
%                      sampler.samplePeriod, sampler.samplePeriod);

    properties
        samplePeriod = 0.1   % s; 100 samples per 10 s window
        UEs                  % nrUE array
        sim                  % wirelessNetworkSimulator handle
        % log{u}: rows [time, appTx, appRx, macTx, macRx], cumulative
        % counters that the extraction differences per window
        log
    end

    properties (Access = private)
        n                    % filled rows per UE (chunk preallocation)
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
            %getLog Trimmed copy of UE u's sample rows.
            L = obj.log{u}(1:obj.n(u), :);
        end
    end
end

function v = getf(s, layer, fld)
%getf Nested-field read returning NaN when a counter is absent, so a renamed
% field shows up as a NaN column instead of killing a run mid-way.
    if isfield(s, layer) && isfield(s.(layer), fld)
        v = double(s.(layer).(fld));
    else
        v = NaN;
    end
end
