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
%                  [time, RNTI, wbCQI_DL, RI_DL, ulMCS_ctx,
%                   cqiSubbandSpread, timingAdvance, bufDL_B, bufUL_B]
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
%
%                PHASE 5 ADDITIONS (columns 6-9), all network-observable:
%                  cqiSubbandSpread - standard deviation of the reported
%                    CQI ACROSS SUBBANDS before the wideband collapse. A
%                    frequency-flat channel gives a spread near zero; a
%                    frequency-selective one gives a large spread. This is
%                    the legitimate operator-side proxy for the LOS-like
%                    propagation an airborne UE experiences, and replaces
%                    any temptation to expose the simulator's own LOS flag
%                    as a feature (which an operator cannot observe and
%                    which would leak the label).
%                  timingAdvance - TS 38.213 clause 4.2 timing advance. A
%                    direct propagation-delay measurement and the single
%                    best operator-side distance proxy. Probed defensively:
%                    NaN when the installed release does not surface it,
%                    with phase4SchedulerCheck reporting the actual layout.
%                  bufDL_B / bufUL_B - buffer occupancy in bytes (the UL
%                    figure is the UE's reported BSR, TS 38.321 clause
%                    6.1.3.1). Queue depth separates a steady uplink video
%                    stream from bursty terrestrial traffic.
%
%     grantLog - one row per scheduling assignment (every TTI, no
%                decimation, both directions, new transmissions AND
%                retransmissions):
%                  [time, RNTI, dir (0 DL / 1 UL), MCSIndex, numRBs,
%                   isRetx, numLayers, harqID]
%                The granted MCS is the gNB's own link adaptation output
%                and is directly observable by the operator.
%
%                PHASE 5 ADDITIONS (columns 6-8):
%                  isRetx - 1 for a retransmission grant, 0 for a new
%                    transmission. The retransmission FRACTION over a
%                    window is a residual-BLER estimate, which is a
%                    standard operator KPI and was previously not captured
%                    at all because only the new-transmission hooks were
%                    instrumented. Determined two ways so a release that
%                    does not expose one still yields the other: the hook
%                    the grant arrived through, and the grant's own
%                    redundancy-version / new-data-indicator field.
%                  numLayers - granted spatial layers, the scheduler's
%                    acted-upon view of the rank.
%                  harqID - HARQ process identifier.
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

        %ctxLog [time, RNTI, wbCQI_DL, RI_DL, ulMCS_ctx, cqiSubbandSpread,
        % timingAdvance, bufDL_B, bufUL_B]; NaN = not available
        ctxLog = zeros(0, 9)

        %grantLog [time, RNTI, dir(0 DL/1 UL), MCSIndex, numRBs, isRetx,
        % numLayers, harqID]
        grantLog = zeros(0, 8)
    end

    properties
        %probeWindow Number of context snapshots over which the timing
        % advance and buffer-status name probes are attempted before being
        % retired as unavailable. 400 snapshots at the default 5 ms
        % ctxLogPeriod is 2 s of simulated time, comfortably past random
        % access and the first CSI reports.
        probeWindow = 400
    end

    properties (Access = private)
        Sim = []              % wirelessNetworkSimulator handle (lazy)
        lastCtxTime = -inf
        ctxN = 0              % filled rows in ctxLog (chunk preallocation)
        grantN = 0            % filled rows in grantLog
        probeActive = true    % name probes still being attempted
        probeFound = false    % a name probe has succeeded at least once
        probeCount = 0        % context snapshots taken so far
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
            obj.recordGrants(varargout{1}, 0, 0);
        end

        function varargout = scheduleNewTransmissionsUL(obj, varargin)
            [varargout{1:max(nargout,1)}] = ...
                scheduleNewTransmissionsUL@nrScheduler(obj, varargin{:});
            obj.snapshotContext();
            obj.recordGrants(varargout{1}, 1, 0);
        end

        % Retransmission hooks (Phase 5). Same delegate-then-log contract:
        % the scheduling DECISION is entirely the stock scheduler's, so
        % adding these does not change radio behaviour, it only stops the
        % retransmission grants from going unrecorded. The isRetx flag is
        % forced to 1 here; recordGrants still inspects RV/NDI so a grant
        % arriving through the new-transmission hook with RV > 0 is also
        % counted.
        function varargout = scheduleRetransmissionsDL(obj, varargin)
            [varargout{1:max(nargout,1)}] = ...
                scheduleRetransmissionsDL@nrScheduler(obj, varargin{:});
            obj.recordGrants(varargout{1}, 0, 1);
        end

        function varargout = scheduleRetransmissionsUL(obj, varargin)
            [varargout{1:max(nargout,1)}] = ...
                scheduleRetransmissionsUL@nrScheduler(obj, varargin{:});
            obj.recordGrants(varargout{1}, 1, 1);
        end
    end

    methods
        function [ctx, grants] = getLogs(obj)
            %getLogs Trimmed copies of the two logs (drop preallocated slack).
            ctx = obj.ctxLog(1:obj.ctxN, :);
            grants = obj.grantLog(1:obj.grantN, :);
        end

        function s = getProbeStatus(obj)
            %getProbeStatus Outcome of the timing-advance / buffer probes.
            %   .found     true if any probe ever resolved a value
            %   .active    true if the probes are still running
            %   .snapshots context snapshots taken
            %   Report this from a diagnostic run: found == false means the
            %   installed release does not surface those quantities and the
            %   ta_* and buffer columns will be NaN for the whole dataset,
            %   which is a fact about the release rather than a bug.
            s = struct('found', obj.probeFound, ...
                'active', obj.probeActive, ...
                'snapshots', obj.probeCount);
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
                % (1) rather than the bare value: on a table-shaped context
                % the member access returns a column, and a vector here
                % would silently widen the log row.
                if isfield_(c, 'RNTI')
                    v = double(c.RNTI);
                    rnti = v(1);
                else
                    rnti = i;
                end

                % --- DL: UE-reported CQI and RI (spoofable, Q3-relevant) ---
                % The R2024b UEContext nests the DL report below
                % CSIMeasurementDL (per-measurement-signal subfields such
                % as CSIRS/SRS), so the probe searches recursively for the
                % first non-empty numeric field named *CQI* rather than
                % assuming one layout. Found via phase4SchedulerCheck C2.
                wbCQI = NaN; ri = NaN; cqiSpread = NaN;
                if isfield_(c, 'CSIMeasurementDL')
                    [wbCQI, ri, cqiSpread] = probeDLCSI_(c.CSIMeasurementDL, 0);
                end

                % --- UL: gNB-side SRS-derived MCS estimate (not spoofable) ---
                ulMcs = NaN;
                if isfield_(c, 'CSIMeasurementUL')
                    u = c.CSIMeasurementUL;
                    if isfield_(u, 'MCSIndex') && ~isempty(u.MCSIndex)
                        ulMcs = double(u.MCSIndex(1));
                    end
                end

                % --- Timing advance (TS 38.213 clause 4.2) ---------------
                % Probed by name across the context, because the release
                % that surfaces it and the level it sits at are not fixed.
                % NaN when absent; phase4SchedulerCheck dumps the layout.
                %
                % The probe is a recursive walk of the whole UEContext, so
                % it is far too expensive to repeat for every UE on every
                % 5 ms snapshot for a quantity the release may not expose
                % at all. probeActive gates it: the walk runs during the
                % opening probeWindow snapshots and, if a quantity has not
                % appeared by then, is switched off for the rest of the run
                % and the column stays NaN. The window is not a single
                % snapshot because timing advance is absent until random
                % access completes, so probing only at t = 0 would give up
                % on a quantity that does arrive shortly afterwards.
                ta = NaN; bufDL = NaN; bufUL = NaN;
                if obj.probeActive
                    ta = probeNumericByName_(c, '^(TimingAdvance|TA|NTA)$', 0);
                    bufDL = probeNumericByName_(c, ...
                        'BufferStatusDL|DLBufferStatus|BufferSizeDL', 0);
                    bufUL = probeNumericByName_(c, ...
                        'BufferStatusUL|ULBufferStatus|BufferSizeUL|BSR', 0);
                    obj.probeFound = obj.probeFound || ...
                        ~isnan(ta) || ~isnan(bufDL) || ~isnan(bufUL);
                end

                obj.appendCtx([t, rnti, wbCQI, ri, ulMcs, cqiSpread, ...
                    ta, bufDL, bufUL]);
            end

            % Retire the name probes once the opening window has passed
            % without finding anything. If they DID find something the
            % layout is stable, so they keep running.
            obj.probeCount = obj.probeCount + 1;
            if obj.probeActive && ~obj.probeFound ...
                    && obj.probeCount >= obj.probeWindow
                obj.probeActive = false;
            end
        end

        function recordGrants(obj, assignments, dir, isRetxHook)
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

                % Retransmission: trust the hook it arrived through, and
                % additionally believe a non-zero redundancy version or a
                % cleared new-data indicator. Either signal alone is
                % enough, so the BLER proxy survives a release that
                % exposes only one of them.
                isRetx = double(isRetxHook ~= 0);
                if isfield_(a, 'RV') && ~isempty(a.RV) && double(a.RV(1)) > 0
                    isRetx = 1;
                end
                if isfield_(a, 'NDI') && ~isempty(a.NDI) && double(a.NDI(1)) == 0 ...
                        && isRetxHook ~= 0
                    isRetx = 1;
                end

                nLayers = NaN;
                for f = {'NumLayers', 'NumTransmissionLayers', 'NLayers'}
                    if isfield_(a, f{1}) && ~isempty(a.(f{1}))
                        nLayers = double(a.(f{1})(1));
                        break;
                    end
                end

                harqID = NaN;
                for f = {'HARQProcessID', 'HARQID', 'HarqProcessID'}
                    if isfield_(a, f{1}) && ~isempty(a.(f{1}))
                        harqID = double(a.(f{1})(1));
                        break;
                    end
                end

                obj.appendGrant([t, rnti, dir, mcs, nRB, isRetx, ...
                    nLayers, harqID]);
            end
        end

        function appendCtx(obj, row)
            % A probe that returned a vector rather than a scalar would
            % otherwise surface as an opaque size error thousands of rows
            % into a multi-hour run. Name the log instead.
            assert(numel(row) == size(obj.ctxLog, 2), ...
                'cqiLoggingScheduler:ctxRowWidth', ...
                ['Context row has %d values for %d columns. One of the ' ...
                 'UEContext probes returned a non-scalar; check the ' ...
                 'CQI, RI, ulMCS, TA and buffer extractions.'], ...
                numel(row), size(obj.ctxLog, 2));
            if obj.ctxN == size(obj.ctxLog, 1)                 % grow in chunks
                obj.ctxLog = [obj.ctxLog; zeros(1e5, size(obj.ctxLog, 2))];
            end
            obj.ctxN = obj.ctxN + 1;
            obj.ctxLog(obj.ctxN, :) = row;
        end

        function appendGrant(obj, row)
            assert(numel(row) == size(obj.grantLog, 2), ...
                'cqiLoggingScheduler:grantRowWidth', ...
                ['Grant row has %d values for %d columns. One of the ' ...
                 'assignment fields returned a non-scalar; check the ' ...
                 'MCS, PRB, RV, layers and HARQ extractions.'], ...
                numel(row), size(obj.grantLog, 2));
            if obj.grantN == size(obj.grantLog, 1)
                obj.grantLog = [obj.grantLog; zeros(1e5, size(obj.grantLog, 2))];
            end
            obj.grantN = obj.grantN + 1;
            obj.grantLog(obj.grantN, :) = row;
        end
    end
end

%% local helpers (struct-or-object safe field probing)
function tf = isfield_(s, f)
%isfield_ Struct field, table variable, or object property, by name.
%   The table branch is checked before the object branch because a table
%   IS an object but isprop does not see its variable names.
    tf = (isstruct(s) && isfield(s, f)) || ...
         ((istable(s) || istimetable(s)) && ...
             any(strcmp(s.Properties.VariableNames, f))) || ...
         (isobject(s) && isprop(s, f));
end

function [cqi, ri, spread] = probeDLCSI_(d, depth)
%probeDLCSI_ Recursive search of a CSI measurement struct for the first
% non-empty numeric field whose name contains CQI (wideband value taken
% as the rounded mean of the vector) and, at the same level or below, a
% rank indicator. Depth-limited so an unexpected layout cannot recurse
% unboundedly; NaN when nothing is found, which phase4SchedulerCheck
% reports together with a dump of the actual layout.
%
% SPREAD (Phase 5) is the standard deviation of the SAME vector before it
% is collapsed to the wideband value: the across-subband variation of the
% reported CQI, i.e. how frequency-selective the channel looks to the UE.
% It is NaN when the report is a scalar (nothing to spread) rather than 0,
% so "no subband information available" is distinguishable from "perfectly
% flat channel"; extractWindowedFeatures relies on that distinction.
    cqi = NaN; ri = NaN; spread = NaN;
    if depth > 4, return; end

    % Normalised through members_ so this walk survives the table level in
    % the R2024b UEContext as well; for a struct it yields exactly the
    % fieldnames in the same order, so the Phase 4 search behaviour is
    % unchanged.
    m = members_(d);
    if isempty(m), return; end
    f = {m.name};

    % Pass 1: CQI/RI fields at this level (exact 'CQI' preferred)
    order = [find(strcmpi(f, 'CQI')), find(~cellfun('isempty', ...
        regexpi(f, 'cqi')) & ~strcmpi(f, 'CQI'))];
    for i = order
        v = m(i).value;
        if isnumeric(v) && ~isempty(v) && any(~isnan(v(:)))
            vv = double(v(:));
            cqi = round(mean(vv, 'omitnan'));
            if sum(~isnan(vv)) >= 2
                spread = std(vv, 0, 'omitnan');
            end
            break;
        end
    end
    for i = 1:numel(f)
        if ~isempty(regexpi(f{i}, '^(RankIndicator|RI)$', 'once'))
            v = m(i).value;
            if isnumeric(v) && ~isempty(v)
                ri = double(v(1));
                break;
            end
        end
    end
    if ~isnan(cqi), return; end

    % Pass 2: recurse into container-valued members, CSI-RS branch first
    order = [find(~cellfun('isempty', regexpi(f, 'csirs'))), ...
             find(cellfun('isempty', regexpi(f, 'csirs')))];
    for i = order
        v = m(i).value;
        if isstruct(v) || isobject(v)
            [cqi2, ri2, sp2] = probeDLCSI_(v, depth + 1);
            if ~isnan(cqi2)
                cqi = cqi2;
                spread = sp2;
                if isnan(ri), ri = ri2; end
                return;
            end
        end
    end
end

function v = probeNumericByName_(s, pattern, depth)
%probeNumericByName_ First numeric scalar whose member name matches PATTERN.
%   Depth-limited recursive search over the UEContext, used for the
%   quantities whose position there is not documented (timing advance,
%   buffer status). Returns NaN when nothing matches, so a release that
%   does not surface the quantity yields an honest NaN column rather than
%   a fabricated value.
    v = NaN;
    if depth > 4, return; end
    m = members_(s);
    if isempty(m), return; end

    for i = 1:numel(m)
        if ~isempty(regexpi(m(i).name, pattern, 'once'))
            x = m(i).value;
            if isnumeric(x) && ~isempty(x) && any(~isnan(double(x(:))))
                v = double(x(1));
                return;
            end
        end
    end

    for i = 1:numel(m)
        x = m(i).value;
        if isstruct(x) || isobject(x)
            v = probeNumericByName_(x, pattern, depth + 1);
            if ~isnan(v), return; end
        end
    end
end

function m = members_(s)
%members_ Name/value pairs of the first element of a struct, object or table.
%
%   The R2024b UEContext is not a uniform container: parts of it are
%   structs, parts are objects, and at least one level is a TABLE. Tables
%   were what broke the first version of the probe, because s(1) is not
%   valid linear indexing on a table - MATLAB requires s(row, var) - so
%   the recursion threw as soon as it reached one. Normalising every
%   container to the same name/value list here means the callers never
%   have to know which kind they are walking, and a container type nobody
%   anticipated degrades to "no members" rather than to an error that
%   kills a multi-hour run part way through.
%
%   Everything is wrapped defensively: a dependent property that errors on
%   read, or a table variable that cannot be indexed, is skipped rather
%   than propagated.
    m = struct('name', {}, 'value', {});
    if isempty(s), return; end

    try
        if istable(s) || istimetable(s)
            if size(s, 1) < 1, return; end
            names = s.Properties.VariableNames;
            for i = 1:numel(names)
                try
                    col = s.(names{i});
                    if iscell(col), val = col{1}; else, val = col(1,:); end
                    k = numel(m) + 1;
                    m(k).name = names{i};
                    m(k).value = val;
                catch
                    % unindexable variable: skip it
                end
            end
            return;
        end

        if isstruct(s)
            s = s(1);
            names = fieldnames(s);
        elseif isobject(s)
            s = s(1);
            names = properties(s);
        else
            return;   % numeric, char, cell: nothing to walk
        end

        for i = 1:numel(names)
            try
                k = numel(m) + 1;
                m(k).name = names{i};
                m(k).value = s.(names{i});
            catch
                % dependent property that errors on read: skip it
            end
        end
    catch
        m = struct('name', {}, 'value', {});
    end
end
