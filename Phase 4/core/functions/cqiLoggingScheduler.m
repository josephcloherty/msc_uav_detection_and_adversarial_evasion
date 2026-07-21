classdef cqiLoggingScheduler < nrScheduler
%cqiLoggingScheduler Custom scheduler with per-UE CQI/MCS logging (D4.1).
%
%   A minimal nrScheduler subclass whose scheduling DECISIONS are those of
%   the stock scheduler: both protected overrides delegate to the base
%   class implementation and only then record what the scheduler saw and
%   granted. This keeps Phase 4 radio behaviour identical to Phase 3 (same
%   default strategy, same grants for the same inputs), so the new CQI,
%   MCS, and traffic columns extend the Phase 3 dataset rather than
%   perturbing the existing SINR and handover columns.
%
%   Plug in per gNB (one instance per gNB, BEFORE connectUE):
%       sched = cqiLoggingScheduler;
%       configureScheduler(gNB, Scheduler=sched);
%
%   What is logged and why it is operator-observable:
%     ctxLog   - snapshot of the scheduler's own UE context, at most every
%                ctxLogPeriod seconds (default 5 ms, well above the CSI
%                report periodicity, so no report is missed):
%                  [time, RNTI, wbCQI_DL, RI_DL, ulMCS_ctx]
%                wbCQI_DL is the wideband value of the UE-reported DL CQI
%                (TS 38.214 clause 5.2.2.1, 4-bit index 0-15; the per-RB
%                subband vector is collapsed by rounded mean). RI_DL is
%                the reported rank indicator. ulMCS_ctx is the MCS index
%                the gNB derived ITSELF from SRS (TS 38.214 clause 6.1.4,
%                index 0-28): the UL quality estimate is gNB-side and is
%                therefore NOT spoofable, unlike the UE-reported CQI. This
%                distinction carries into the Q3 threat model: falsified
%                CQI propagates into granted DL MCS, while the SRS-derived
%                UL estimate stays honest.
%     grantLog - one row per scheduling assignment (every TTI, no
%                decimation, both directions):
%                  [time, RNTI, dir (0 DL / 1 UL), MCSIndex, numRBs]
%                The granted MCS is the gNB's own link adaptation output
%                and is directly observable by the operator.
%
%   R2024b VERIFICATION REQUIRED BEFORE FIRST USE (the plan's D4.1 check;
%   run phase4SchedulerCheck.m and log the outcome):
%     1) configureScheduler accepts a custom nrScheduler subclass via the
%        Scheduler name-value argument (the "Use Custom Scheduler in 5G
%        System-Level Simulation" example is the reference).
%     2) The base-class protected methods scheduleNewTransmissionsDL/UL
%        exist and are callable via the superclass syntax used below, so
%        delegation reproduces stock behaviour.
%     3) UEContext carries CSIMeasurementDL (fields incl. CQI, possibly
%        RankIndicator) and CSIMeasurementUL (field MCSIndex). The field
%        probing below is written defensively (NaN when absent) precisely
%        so the check script can report what R2024b actually provides.
%
%   New file for Phase 4 (standalone class, no Fudan or MathWorks source
%   modified), keeping the scaffold/contribution boundary clean.

    properties
        %ctxLogPeriod Minimum spacing (s) between UE-context snapshots.
        % 5 ms is far below the window length (10 s) and above the TTI
        % rate, so the log stays small without losing CSI updates.
        ctxLogPeriod = 0.005

        %ctxLog [time, RNTI, wbCQI_DL, RI_DL, ulMCS_ctx]; NaN = not available
        ctxLog = zeros(0, 5)

        %grantLog [time, RNTI, dir(0 DL/1 UL), MCSIndex, numRBs]
        grantLog = zeros(0, 5)
    end

    properties (Access = private)
        Sim = []              % wirelessNetworkSimulator handle (lazy)
        lastCtxTime = -inf
        ctxN = 0              % filled rows in ctxLog (chunk preallocation)
        grantN = 0            % filled rows in grantLog
    end

    methods (Access = protected)
        % Delegation is signature-proof: the R2024b base class invokes
        % these methods as (obj, timeResource, frequencyAllocationBitmap,
        % schedulingInfo), which differs from the current online reference
        % (single schedulingInfo struct). Passing varargin through means
        % the overrides track whatever signature the installed release
        % uses; only the first output (the grant list) is inspected, and
        % defensively. Found by the first phase4SchedulerCheck run on
        % R2024b; recorded in the deviations log.
        function varargout = scheduleNewTransmissionsDL(obj, varargin)
            % Delegate the DECISION to the stock scheduler, then log.
            [varargout{1:max(nargout,1)}] = ...
                scheduleNewTransmissionsDL@nrScheduler(obj, varargin{:});
            obj.snapshotContext();
            obj.recordGrants(varargout{1}, 0);
        end

        function varargout = scheduleNewTransmissionsUL(obj, varargin)
            [varargout{1:max(nargout,1)}] = ...
                scheduleNewTransmissionsUL@nrScheduler(obj, varargin{:});
            obj.snapshotContext();
            obj.recordGrants(varargout{1}, 1);
        end
    end

    methods
        function [ctx, grants] = getLogs(obj)
            %getLogs Trimmed copies of the two logs (drop preallocated slack).
            ctx = obj.ctxLog(1:obj.ctxN, :);
            grants = obj.grantLog(1:obj.grantN, :);
        end
    end

    methods (Access = private)
        function t = now_(obj)
            if isempty(obj.Sim)
                obj.Sim = wirelessNetworkSimulator.getInstance();
            end
            t = obj.Sim.CurrentTime;
        end

        function snapshotContext(obj)
            t = obj.now_();
            if t - obj.lastCtxTime < obj.ctxLogPeriod
                return;
            end
            obj.lastCtxTime = t;

            ueCtx = obj.UEContext;
            for i = 1:numel(ueCtx)
                c = ueCtx(i);
                % RNTI: prefer the declared field; fall back to the index
                % (UEContext is RNTI-indexed in the shipped helpers).
                if isfield_(c, 'RNTI'), rnti = double(c.RNTI); else, rnti = i; end

                % --- DL: UE-reported CQI and RI (spoofable, Q3-relevant) ---
                % The R2024b UEContext nests the DL report below
                % CSIMeasurementDL (per-measurement-signal subfields such
                % as CSIRS/SRS), so the probe searches recursively for the
                % first non-empty numeric field named *CQI* rather than
                % assuming one layout. Found via phase4SchedulerCheck C2.
                wbCQI = NaN; ri = NaN;
                if isfield_(c, 'CSIMeasurementDL')
                    [wbCQI, ri] = probeDLCSI_(c.CSIMeasurementDL, 0);
                end

                % --- UL: gNB-side SRS-derived MCS estimate (not spoofable) ---
                ulMcs = NaN;
                if isfield_(c, 'CSIMeasurementUL')
                    u = c.CSIMeasurementUL;
                    if isfield_(u, 'MCSIndex') && ~isempty(u.MCSIndex)
                        ulMcs = double(u.MCSIndex(1));
                    end
                end

                obj.appendCtx([t, rnti, wbCQI, ri, ulMcs]);
            end
        end

        function recordGrants(obj, assignments, dir)
            if isempty(assignments), return; end
            t = obj.now_();
            for k = 1:numel(assignments)
                a = assignments(k);
                if isfield_(a, 'RNTI'), rnti = double(a.RNTI); else, rnti = NaN; end
                if isfield_(a, 'MCSIndex'), mcs = double(a.MCSIndex); else, mcs = NaN; end
                nRB = NaN;
                if isfield_(a, 'FrequencyAllocation') && ~isempty(a.FrequencyAllocation)
                    fa = a.FrequencyAllocation;
                    if numel(fa) == 2          % RAT-1: [start, numRBs]
                        nRB = double(fa(2));
                    else                        % RAT-0: RBG bitmap
                        nRB = double(sum(fa(:)));
                    end
                end
                obj.appendGrant([t, rnti, dir, mcs, nRB]);
            end
        end

        function appendCtx(obj, row)
            if obj.ctxN == size(obj.ctxLog, 1)                 % grow in chunks
                obj.ctxLog = [obj.ctxLog; zeros(1e5, 5)];
            end
            obj.ctxN = obj.ctxN + 1;
            obj.ctxLog(obj.ctxN, :) = row;
        end

        function appendGrant(obj, row)
            if obj.grantN == size(obj.grantLog, 1)
                obj.grantLog = [obj.grantLog; zeros(1e5, 5)];
            end
            obj.grantN = obj.grantN + 1;
            obj.grantLog(obj.grantN, :) = row;
        end
    end
end

%% local helpers (struct-or-object safe field probing)
function tf = isfield_(s, f)
    tf = (isstruct(s) && isfield(s, f)) || ...
         (isobject(s) && isprop(s, f));
end

function [cqi, ri] = probeDLCSI_(d, depth)
%probeDLCSI_ Recursive search of a CSI measurement struct for the first
% non-empty numeric field whose name contains CQI (wideband value taken
% as the rounded mean of the vector) and, at the same level or below, a
% rank indicator. Depth-limited so an unexpected layout cannot recurse
% unboundedly; NaN when nothing is found, which phase4SchedulerCheck
% reports together with a dump of the actual layout.
    cqi = NaN; ri = NaN;
    if depth > 4 || ~isstruct(d) || isempty(d)
        return;
    end
    d = d(1);
    f = fieldnames(d);

    % Pass 1: CQI/RI fields at this level (exact 'CQI' preferred)
    order = [find(strcmpi(f, 'CQI')); find(~cellfun('isempty', ...
        regexpi(f, 'cqi')) & ~strcmpi(f, 'CQI'))];
    for i = order'
        v = d.(f{i});
        if isnumeric(v) && ~isempty(v) && any(~isnan(v(:)))
            cqi = round(mean(double(v(:)), 'omitnan'));
            break;
        end
    end
    for i = 1:numel(f)
        if ~isempty(regexpi(f{i}, '^(RankIndicator|RI)$', 'once'))
            v = d.(f{i});
            if isnumeric(v) && ~isempty(v)
                ri = double(v(1));
                break;
            end
        end
    end
    if ~isnan(cqi), return; end

    % Pass 2: recurse into struct-valued fields, CSI-RS branch first
    order = [find(~cellfun('isempty', regexpi(f, 'csirs'))); ...
             find(cellfun('isempty', regexpi(f, 'csirs')))];
    for i = order'
        if isstruct(d.(f{i}))
            [cqi2, ri2] = probeDLCSI_(d.(f{i}), depth + 1);
            if ~isnan(cqi2)
                cqi = cqi2;
                if isnan(ri), ri = ri2; end
                return;
            end
        end
    end
end
