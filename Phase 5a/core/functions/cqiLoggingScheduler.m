classdef cqiLoggingScheduler < nrScheduler
% nrScheduler subclass that logs each UE's CSI context and every grant, while
% delegating all scheduling decisions to the stock scheduler.

    properties
        % minimum spacing (s) between context snapshots
        ctxLogPeriod = 0.005

        % context rows, NaN where unavailable
        ctxLog = zeros(0, 9)

        % grant rows, one per assignment
        grantLog = zeros(0, 8)
    end

    properties
        % snapshots to attempt the name probes over
        probeWindow = 400
    end

    properties (Access = private)
        Sim = []              % simulator handle
        lastCtxTime = -inf
        ctxN = 0              % filled context rows
        grantN = 0            % filled grant rows
        probeActive = true    % probes still running
        probeFound = false    % a probe succeeded
        probeCount = 0        % snapshots taken
    end

    methods (Access = protected)
        % varargin passes the call through, so the overrides track whatever
        % signature the installed release uses.
        function varargout = scheduleNewTransmissionsDL(obj, varargin)
            % delegate the decision, then log
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

        % retransmission hooks, same delegate-then-log contract.
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
            % returns trimmed copies of the two logs.
            ctx = obj.ctxLog(1:obj.ctxN, :);
            grants = obj.grantLog(1:obj.grantN, :);
        end

        function s = getProbeStatus(obj)
            % returns the outcome of the timing-advance and buffer probes.
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
                % prefer the declared field, else the index
                if isfield_(c, 'RNTI')
                    v = double(c.RNTI);
                    rnti = v(1);
                else
                    rnti = i;
                end

                % DL: UE-reported CQI and RI, found by recursive probe
                wbCQI = NaN; ri = NaN; cqiSpread = NaN;
                if isfield_(c, 'CSIMeasurementDL')
                    [wbCQI, ri, cqiSpread] = probeDLCSI_(c.CSIMeasurementDL, 0);
                end

                % UL: gNB-side SRS-derived MCS estimate
                ulMcs = NaN;
                if isfield_(c, 'CSIMeasurementUL')
                    u = c.CSIMeasurementUL;
                    if isfield_(u, 'MCSIndex') && ~isempty(u.MCSIndex)
                        ulMcs = double(u.MCSIndex(1));
                    end
                end

                % timing advance, probed by name across the context
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

            % retire the probes if the opening window found nothing
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
                    if numel(fa) == 2          % RAT-1 allocation
                        nRB = double(fa(2));
                    else                        % RBG bitmap
                        nRB = double(sum(fa(:)));
                    end
                end

                % treat a non-zero RV or cleared NDI as a retransmission too
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
            % name the log rather than throwing a size error
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

%% local helpers
function tf = isfield_(s, f)
% returns true when a name is a struct field, table variable or property.
    tf = (isstruct(s) && isfield(s, f)) || ...
         ((istable(s) || istimetable(s)) && ...
             any(strcmp(s.Properties.VariableNames, f))) || ...
         (isobject(s) && isprop(s, f));
end

function [cqi, ri, spread] = probeDLCSI_(d, depth)
% searches a CSI measurement container for the first CQI value, its rank
% indicator and the across-subband spread of the same vector.
    cqi = NaN; ri = NaN; spread = NaN;
    if depth > 4, return; end

    % members_ normalises struct, object and table levels
    m = members_(d);
    if isempty(m), return; end
    f = {m.name};

    % pass 1: CQI and RI at this level
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

    % pass 2: recurse into containers
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
% returns the first numeric scalar whose member name matches a pattern, or NaN.
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
% returns name/value pairs for a struct, object or table, so the probes can walk
% any of them without knowing which they have.
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
                    % skip unindexable variable
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
            return;   % nothing to walk
        end

        for i = 1:numel(names)
            try
                k = numel(m) + 1;
                m(k).name = names{i};
                m(k).value = s.(names{i});
            catch
                % skip property that errors
            end
        end
    catch
        m = struct('name', {}, 'value', {});
    end
end
