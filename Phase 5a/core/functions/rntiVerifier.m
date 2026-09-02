classdef rntiVerifier < handle
% checks once per run that the SRS RNTI offset actually matches the events the
% handover managers receive, and either corrects it or aborts.

    properties
        expected                % expected SRS RNTIs
        ueIDs     = []          % node ids
        observed  = []          % RNTIs seen
        managers  = {}          % handover managers
        checkTime = 0.5         % seconds
        autoCorrect = false
        quiet     = false
        label     = ""          % run label
        done      = false
        passed    = false
        listener  = []
    end

    methods
        function obj = rntiVerifier(gNBs, sim, expected, managers, opts)
            obj.expected = expected(:)';
            obj.managers = managers;
            obj.ueIDs = cellfun(@(m) m.UE.ID, managers(:)');
            if nargin >= 5 && ~isempty(opts)
                if isfield(opts, 'checkTime'),   obj.checkTime   = opts.checkTime;   end
                if isfield(opts, 'autoCorrect'), obj.autoCorrect = opts.autoCorrect; end
                if isfield(opts, 'quiet'),       obj.quiet       = opts.quiet;       end
                if isfield(opts, 'label'),       obj.label       = string(opts.label); end
            end
            obj.listener = addlistener(gNBs, 'PacketReceptionEnded', ...
                @(src, ev) obj.capture(src, ev));
            scheduleAction(sim, @(varargin) obj.check(), [], obj.checkTime);
        end

        function capture(obj, ~, event)
            % records the RNTI of one SRS reception.
            if obj.done, return; end
            if strcmp(event.EventName, "PacketReceptionEnded") && ...
                    strcmp(event.Data.SignalType, "SRS")
                obj.observed(end+1) = event.Data.RNTI;
            end
        end

        function check(obj, varargin)
            % one-shot verdict, then stop listening.
            obj.done = true;
            % listener arrays cannot go through &&
            delete(obj.listener);
            obj.listener = [];

            obs = unique(obj.observed);
            exp = obj.expected;

            if isempty(obs)
                error('rntiVerifier:noSRS', ...
                    ['%s: no SRS reception was observed in the first ' ...
                     '%.2f s. The measurement chain is not running at ' ...
                     'all, so no SINR or handover feature would be ' ...
                     'produced. Check configureULforSRS and the SRS ' ...
                     'capacity limit before spending a full run on ' ...
                     'this.'], obj.tag(), obj.checkTime);
            end

            if all(ismember(exp, obs))
                obj.passed = true;
                if ~obj.quiet
                    fprintf(['RNTI check [%s]: SRS offset %+d confirmed, ' ...
                        'all %d UE identifiers observed (expected %s, ' ...
                        'saw %s).\n'], obj.tag(), obj.offsetOf(), ...
                        numel(exp), mat2str(exp), mat2str(obs));
                end
                return;
            end

            % report the shift that would line them up
            delta = min(obs) - min(exp);
            consistent = all(ismember(exp + delta, obs));

            if consistent && obj.autoCorrect
                for u = 1:numel(obj.managers)
                    obj.managers{u}.ueRNTI = exp(u) + delta;
                end
                obj.expected = exp + delta;
                obj.passed = true;
                warning('rntiVerifier:corrected', ...
                    ['%s: SRS RNTI offset was %+d but the observed ' ...
                     'events require %+d. Corrected in place at t=%.2f s, ' ...
                     'inside the settle window, so no dataset row is ' ...
                     'affected. Update cfg.measurement.rntiOffset to %+d ' ...
                     'and record it in the run notes.'], obj.tag(), ...
                    obj.offsetOf(), obj.offsetOf() + delta, obj.checkTime, ...
                    obj.offsetOf() + delta);
                return;
            end

            if consistent
                error('rntiVerifier:wrongOffset', ...
                    ['%s: SRS RNTI mismatch. Expected %s, observed %s. ' ...
                     'A single shift of %+d lines these up, so set ' ...
                     'cfg.measurement.rntiOffset to %+d (currently %+d) ' ...
                     'and note the change. Set ' ...
                     'cfg.measurement.autoCorrectRNTI true to have long ' ...
                     'batches self-correct instead of aborting.'], ...
                    obj.tag(), mat2str(exp), mat2str(obs), delta, ...
                    obj.offsetOf() + delta, obj.offsetOf());
            end

            error('rntiVerifier:noConsistentOffset', ...
                ['%s: SRS RNTI mismatch with no single offset that ' ...
                 'explains it. Expected %s, observed %s. The identifiers ' ...
                 'are not a shifted node numbering on this configuration, ' ...
                 'so run phase5_SchedulerDiag and re-derive the ' ...
                 'convention rather than adjusting the offset.'], ...
                obj.tag(), mat2str(exp), mat2str(obs));
        end
    end

    methods (Access = private)
        function o = offsetOf(obj)
            % returns the offset implied by the current expectation.
            if isempty(obj.expected) || isempty(obj.ueIDs)
                o = 0;
            else
                o = obj.expected(1) - obj.ueIDs(1);
            end
        end

        function s = tag(obj)
            if strlength(obj.label) > 0, s = char(obj.label);
            else, s = 'run'; end
        end
    end
end
