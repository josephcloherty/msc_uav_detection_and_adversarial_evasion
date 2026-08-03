classdef rntiVerifier < handle
%rntiVerifier In-flight check of the SRS RNTI offset, once per run.
%
%   The scheduler RNTI is resolved from the toolbox connection tables and
%   needs no calibration (phase5_ResolveRNTI). The SRS RNTI does: the
%   handover managers identify their UE's SRS events as
%   UE.ID + cfg.rntiOffset, and that offset is an empirical constant. It
%   has held at three, five and seven gNBs, but nothing enforces it, and
%   a wrong value fails silently: the managers simply ingest nothing, and
%   the run completes producing a full CSV of NaN SINR columns after
%   hours of compute.
%
%   Phases 2 and 3 calibrated the offset by hand and carried the number
%   forward. That is exactly how a value correct for a three-cell layout
%   came to be used unchallenged on larger ones. This class makes the
%   check automatic and per run.
%
%   HOW IT WORKS
%   A listener records the RNTI of every SRS reception until a one-shot
%   check fires at CHECKTIME (default: the settle time, so the check
%   window is inside the span the extraction discards anyway). At that
%   point:
%
%     - every expected RNTI observed          pass, one confirmation line
%     - none observed, but a single offset
%       delta lines the two sets up           either correct the managers
%                                             in place (autoCorrect) or
%                                             abort naming the value
%     - no consistent offset                  abort, listing both sets
%
%   The listener is deleted as soon as the check fires, so it costs
%   nothing for the remaining hours of the run.
%
%   Auto-correction is off by default, in keeping with the rest of the
%   pipeline preferring a loud failure to a silent repair. It is worth
%   enabling for long unattended batches, where losing a thirteen hour
%   run to a recalibratable constant is the worse outcome; the correction
%   is applied inside the settle window, so no row in the dataset is
%   computed from measurements taken under the wrong identifier.

    properties
        expected                % 1 x numUE expected SRS RNTIs
        ueIDs     = []          % 1 x numUE node IDs, to report the offset
        observed  = []          % every SRS RNTI seen before the check
        managers  = {}          % handover managers, for auto-correction
        checkTime = 0.5         % s
        autoCorrect = false
        quiet     = false
        label     = ""          % "<scenario> seed <n>", for messages
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
            %capture Record the RNTI of one SRS reception.
            if obj.done, return; end
            if strcmp(event.EventName, "PacketReceptionEnded") && ...
                    strcmp(event.Data.SignalType, "SRS")
                obj.observed(end+1) = event.Data.RNTI;
            end
        end

        function check(obj, varargin)
            %check One-shot verdict, then stop listening.
            obj.done = true;
            % addlistener over an ARRAY of gNBs returns an array of
            % listeners, so isvalid() here is a vector and cannot go
            % through &&. delete accepts an array and is a no-op on empty
            % or already-invalid handles, so no scalar guard is needed.
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

            % One consistent shift would line the two sets up: report it
            % as the correction rather than making the user derive it.
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
                     'and record it in the deviations log.'], obj.tag(), ...
                    obj.offsetOf(), obj.offsetOf() + delta, obj.checkTime, ...
                    obj.offsetOf() + delta);
                return;
            end

            if consistent
                error('rntiVerifier:wrongOffset', ...
                    ['%s: SRS RNTI mismatch. Expected %s, observed %s. ' ...
                     'A single shift of %+d lines these up, so set ' ...
                     'cfg.measurement.rntiOffset to %+d (currently %+d) ' ...
                     'and record the change in the deviations log. Set ' ...
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
            %offsetOf The offset implied by the current expectation.
            %   Computed from the stored UE node IDs rather than held as
            %   its own field, so it stays correct after an
            %   auto-correction shifts the expectation.
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
