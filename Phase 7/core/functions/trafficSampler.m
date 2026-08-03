classdef trafficSampler < handle
%trafficSampler Periodic per-UE traffic byte sampling (D4.1/D4.2 support).
%
%   Samples each UE's cumulative byte counters every samplePeriod seconds
%   of simulation time, giving the time series that the windowed traffic
%   features (volume, burstiness, DL/UL asymmetry, throughput) are
%   computed from in extractWindowedFeatures. End-of-run statistics()
%   totals cannot provide these: burstiness in particular needs the
%   within-window increment series (the Phase 1 script phase1_singlecell_t
%   already made this argument: constant and bursty sources look identical
%   at run-level totals).
%
%   Observability framing: the features are computed from the MAC-layer
%   counters (MAC.TransmittedBytes / MAC.ReceivedBytes), i.e. the bytes
%   that actually cross the radio interface, which is what a network
%   operator meters. The App-layer counters are logged alongside purely
%   for diagnostics (they are what the UE generated, not what the network
%   saw). Field names confirmed against the Phase 1 statistics extraction
%   (App.TransmittedBytes, App.ReceivedBytes, MAC.TransmittedBytes,
%   MAC.ReceivedBytes on R2024b).
%
%   Wiring (scenario pipeline):
%       sampler = trafficSampler(UEs, networkSimulator);
%       scheduleAction(networkSimulator, @sampler.sample, [], ...
%                      sampler.samplePeriod, sampler.samplePeriod);
%
%   New file for Phase 4 (standalone class, nothing upstream modified).

    properties
        samplePeriod = 0.1   % s; 100 samples per 10 s window
        UEs                  % nrUE array
        sim                  % wirelessNetworkSimulator handle
        % log{u}: rows [time, appTxBytes, appRxBytes, macTxBytes, macRxBytes]
        % (cumulative counters; extraction differences them per window)
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
%getf Defensive nested-field read: NaN when a counter is absent so a
% renamed field surfaces as NaN columns (and a failed check) rather than
% a hard error mid-run. phase4SchedulerCheck verifies the names once.
    if isfield(s, layer) && isfield(s.(layer), fld)
        v = double(s.(layer).(fld));
    else
        v = NaN;
    end
end
