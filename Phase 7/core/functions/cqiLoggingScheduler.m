classdef cqiLoggingScheduler < nrScheduler
%cqiLoggingScheduler Custom scheduler with per-UE CQI/MCS logging.
%
%   An nrScheduler subclass that delegates every scheduling decision to the
%   base class and then records what it saw and granted. Radio behaviour is
%   unchanged.
%
%   Plug one instance in per gNB, before connectUE:
%       sched = cqiLoggingScheduler;
%       configureScheduler(gNB, Scheduler=sched);
%
%   ctxLog snapshots the UE context at most every ctxLogPeriod seconds:
%     [time, RNTI, wbCQI_DL, RI_DL, ulMCS_ctx, cqiSubbandSpread,
%      timingAdvance, bufDL_B, bufUL_B]
%
%     wbCQI_DL          UE-reported, so spoofable; ulMCS_ctx is gNB-derived
%                       from SRS
%     cqiSubbandSpread  across-subband CQI deviation before the wideband
%                       collapse, near zero on a flat channel
%     timingAdvance     NaN when the release does not surface it
%     bufDL_B/bufUL_B   queue depth
%
%   grantLog has one row per scheduling assignment, both directions, new and
%   retransmitted:
%     [time, RNTI, dir (0 DL / 1 UL), MCSIndex, numRBs, isRetx, numLayers,
%      harqID]
%
%   isRetx is determined two ways, from the hook the grant arrived through
%   and from its own RV/NDI field, so a release exposing only one works.
%
%   Before first use on a new release, run phase4SchedulerCheck.m and confirm:
%     1) configureScheduler takes a custom nrScheduler subclass
%     2) scheduleNewTransmissionsDL/UL are callable via the superclass syntax
%        used below
%     3) UEContext carries CSIMeasurementDL and CSIMeasurementUL

    properties
        %ctxLogPeriod Minimum spacing (s) between UE-context snapshots.
        % 5 ms keeps the log small without losing CSI updates.
        ctxLogPeriod = 0.005

        %ctxLog [time, RNTI, wbCQI_DL, RI_DL, ulMCS_ctx, cqiSubbandSpread,
        % timingAdvance, bufDL_B, bufUL_B]; NaN = not available
        ctxLog = zeros(0, 9)

        %grantLog [time, RNTI, dir(0 DL/1 UL), MCSIndex, numRBs, isRetx,
        % numLayers, harqID]
        grantLog = zeros(0, 8)
    end

    properties
        %probeWindow Snapshots to attempt the name probes over before
        % giving up. 400 at the default period is 2 s of simulated time,
        % past random access and the first CSI reports.
        probeWindow = 400
    end

    properties (Access = private)
        Sim = []              % wirelessNetworkSimulator handle, lazy
        lastCtxTime = -inf
        ctxN = 0              % filled rows; the logs grow in chunks
        grantN = 0
        probeActive = true
        probeFound = false
        probeCount = 0
    end

    methods (Access = protected)
        % varargin passes straight through, because the R2024b base class
        % calls these with a different signature from the online reference
        % and only the grant list is inspected anyway.
        function varargout = scheduleNewTransmissionsDL(obj, varargin)
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

        % isRetx is forced to 1 here, but recordGrants still checks RV/NDI
        % so a retransmission arriving through the other hook is caught too.
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
            %   .found     true if any probe ever resolved a value; false
            %              means the release does not surface those
            %              quantities and the ta_* and buffer columns stay NaN
            %   .active    true if the probes are still running
            %   .snapshots context snapshots taken
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
                % Falls back to the index because UEContext is RNTI-indexed
                % in the shipped helpers. (1) rather than the bare value,
                % because a table-shaped context returns a column.
                if isfield_(c, 'RNTI')
                    v = double(c.RNTI);
                    rnti = v(1);
                else
                    rnti = i;
                end

                % R2024b nests the report below CSIMeasurementDL, so the
                % probe searches rather than assuming one layout.
                wbCQI = NaN; ri = NaN; cqiSpread = NaN;
                if isfield_(c, 'CSIMeasurementDL')
                    [wbCQI, ri, cqiSpread] = probeDLCSI_(c.CSIMeasurementDL, 0);
                end

                ulMcs = NaN;   % gNB-side SRS-derived, not spoofable
                if isfield_(c, 'CSIMeasurementUL')
                    u = c.CSIMeasurementUL;
                    if isfield_(u, 'MCSIndex') && ~isempty(u.MCSIndex)
                        ulMcs = double(u.MCSIndex(1));
                    end
                end

                % Probed by name because neither the release nor the level
                % is fixed. Too expensive to repeat every 5 ms, so it runs
                % over the opening probeWindow snapshots; one snapshot will
                % not do, since TA is absent until random access completes.
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

            % Retired only if the opening window found nothing.
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
                    else                       % RAT-0: RBG bitmap
                        nRB = double(sum(fa(:)));
                    end
                end

                % Either signal alone is enough: the hook it arrived
                % through, or a non-zero RV / cleared NDI.
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
            % Named, or a probe returning a vector shows up as an opaque
            % size error hours into a run.
            assert(numel(row) == size(obj.ctxLog, 2), ...
                'cqiLoggingScheduler:ctxRowWidth', ...
                ['Context row has %d values for %d columns. One of the ' ...
                 'UEContext probes returned a non-scalar; check the ' ...
                 'CQI, RI, ulMCS, TA and buffer extractions.'], ...
                numel(row), size(obj.ctxLog, 2));
            if obj.ctxN == size(obj.ctxLog, 1)
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

function tf = isfield_(s, f)
%isfield_ Struct field, table variable, or object property, by name.
%   Check the table branch first, because a table is an object but isprop
%   cannot see its variable names.
    tf = (isstruct(s) && isfield(s, f)) || ...
         ((istable(s) || istimetable(s)) && ...
             any(strcmp(s.Properties.VariableNames, f))) || ...
         (isobject(s) && isprop(s, f));
end

function [cqi, ri, spread] = probeDLCSI_(d, depth)
%probeDLCSI_ Recursive, depth-limited search for the first non-empty numeric
% field named *CQI* and a rank indicator at the same level or below.
%
% SPREAD is the deviation of that same vector before the wideband collapse,
% i.e. how frequency-selective the channel looks to the UE. NaN rather than 0
% for a scalar report, so "no subband information" stays distinguishable from
% "perfectly flat"; extractWindowedFeatures relies on that.
    cqi = NaN; ri = NaN; spread = NaN;
    if depth > 4, return; end

    % members_ so the walk survives the table level in R2024b UEContext.
    m = members_(d);
    if isempty(m), return; end
    f = {m.name};

    % Pass 1: CQI/RI fields at this level, exact 'CQI' preferred.
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

    % Pass 2: recurse into container-valued members, CSI-RS branch first.
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
%   Used for quantities whose position in the UEContext is undocumented.
%   Returns NaN when nothing matches, rather than fabricating a value.
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
%   The R2024b UEContext mixes structs, objects and at least one table, and
%   s(1) is not valid indexing on a table, so nothing may be indexed
%   directly. An unexpected container gives "no members" rather than an
%   error, and any member that throws on read is skipped.
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
                catch   % unindexable variable
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
            catch   % dependent property that errors on read
            end
        end
    catch
        m = struct('name', {}, 'value', {});
    end
end
