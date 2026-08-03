function T = extractWindowedFeatures(managers, cfg, sched, trafficLogs)
%extractWindowedFeatures Per-UE sliding-window feature extraction (D5.2).
%
%   T = extractWindowedFeatures(MANAGERS, CFG, SCHED, TRAFFICLOGS)
%   converts the per-scan featureLog rows accumulated by each
%   handoverManager, the CQI/MCS/HARQ logs collected by the per-gNB
%   cqiLoggingScheduler instances, and the traffic byte series into
%   windowed feature rows, one row per UE per window position. Every
%   feature is computed only from network-side observables (per-gNB SRS
%   SINR, handover and serving-cell history, scheduler CSI reports and
%   grants, HARQ outcomes, timing advance, MAC byte counters), never from
%   UE position, velocity, altitude, identity, or the simulator's LOS
%   state.
%
%   This is the Phase 5 extension of the Phase 4 function. The Phase 3 and
%   Phase 4 windowing rules, settle gating, column definitions and
%   determinism guarantees are UNCHANGED, and those columns are computed
%   by the same code as before, so a Phase 5 CSV truncated to the Phase 4
%   columns is byte-identical to the Phase 4 file for the same seed. The
%   new columns are strictly appended; see phase5FeatureSchema for the
%   full list and the rationale for each block.
%
%   SCHED is a struct wiring the scheduler logs to UEs:
%       sched.ctx       - cell array, one per gNB: the ctxLog matrix from
%                         that gNB's cqiLoggingScheduler.getLogs(),
%                         [time, RNTI, wbCQI_DL, RI_DL, ulMCS_ctx,
%                          cqiSubbandSpread, timingAdvance, bufDL, bufUL].
%                         Columns 6-9 are the Phase 5 additions; a log
%                         with only the Phase 4 columns is accepted and
%                         the new features come out NaN, so
%                         validateFeatureExtraction can still drive this
%                         function with the older synthetic fixtures.
%       sched.grants    - cell array, one per gNB: the grantLog matrix,
%                         [time, RNTI, dir(0 DL/1 UL), MCSIndex, numRBs,
%                          isRetx, numLayers, harqID]. Same tolerance for
%                         the shorter Phase 4 layout.
%       sched.anchorIdx - 1 x numUE, index (into the cells) of each UE's
%                         ANCHOR gNB: the cell that holds its physical
%                         data link for the whole run. Under the logical
%                         handover model (see the Phase 3 deviations log)
%                         the data link never moves, so the anchor's
%                         scheduler is where this UE's CQI reports,
%                         grants, and traffic live. In a real network
%                         these observables would follow the serving
%                         cell; here they follow the anchor. This weakens
%                         every scheduler-derived feature below and is
%                         recorded as a Phase 4 deviations entry.
%       sched.rnti      - 1 x numUE, the RNTI identifying each UE in the
%                         scheduler logs: the UE's CONNECTION INDEX at its
%                         anchor gNB, read from that gNB's own connection
%                         table, NOT the node-derived UE.ID + cfg.rntiOffset
%                         the handover managers use for SRS events. The two
%                         conventions coincide only for a one or two cell
%                         layout; using the SRS one here emptied the whole
%                         CQI and MCS block at five and seven gNBs. See
%                         phase5_Pipeline and the deviations log.
%
%   TRAFFICLOGS is a cell array, one matrix per UE (from
%   trafficSampler.getLog): cumulative byte counters at 0.1 s spacing,
%   [time, appTxBytes, appRxBytes, macTxBytes, macRxBytes], differenced
%   at the window edges here.
%
%   The cell-geometry block additionally reads MANAGERS{k}.sinrLog, the
%   per-scan snapshot of averaged SINR towards EVERY cell. Up to Phase 4
%   this log was written and never read. It is what makes the "how many
%   cells does this UE hear at comparable strength" family of features
%   possible, which is the most direct measurement of the elevated-UE
%   geometry that the aerial label describes.
%
%   Settle gating: windows are anchored at the first retained scan (as in
%   Phase 3), so scheduler and traffic rows in the settle span never fall
%   inside any window. The sinrLog is filtered by the same settle rule as
%   the featureLog. Traffic deltas difference cumulative counters at the
%   window edges, so pre-window accumulation cancels by construction.
%
%   NaN semantics: NaN means "no observation of this kind in this window"
%   - no CSI report, no grant, no traffic, fewer than two samples for a
%   slope or an autocorrelation, or a quantity the installed MATLAB
%   release does not expose. NaN is never used to mean zero. Counts and
%   rates that are genuinely zero are written as 0.
%
%   Determinism: every feature is a deterministic function of the run
%   logs. polyfit, the step interpolation and the quantile helper
%   introduce no randomness, so the fixed-seed byte-identical
%   regeneration contract carries over.

    if ~isfield(cfg, 'windowLen'),    cfg.windowLen = 10;   end
    if ~isfield(cfg, 'windowStride'), cfg.windowStride = 1; end
    if ~isfield(cfg, 'settleTime'),   cfg.settleTime = 0;   end

    schema = phase5FeatureSchema();
    rows = [];   % numeric part, assembled row by row
    scen = string(cfg.scenario);

    for k = 1:numel(managers)
        m = managers{k};
        fl = m.featureLog;
        if isempty(fl)
            warning('extractWindowedFeatures:emptyLog', ...
                'No feature rows for %s; UE skipped.', m.UE.Name);
            continue;
        end

        % Guard: bind column indices to the names declared upstream.
        names = m.featureNames;
        cTime   = strcmp(names, 'time');
        cServ   = strcmp(names, 'servingSINR');
        cVis    = strcmp(names, 'numVisible');
        cMaxN   = strcmp(names, 'maxNeighbourSINR');
        cMeanN  = strcmp(names, 'meanNeighbourSINR');
        cSpread = strcmp(names, 'sinrSpread');
        cSrvID  = strcmp(names, 'servingGNB');
        cTSince = strcmp(names, 'timeSinceLastHO');
        assert(all([any(cTime) any(cServ) any(cVis) any(cMaxN) ...
            any(cMeanN) any(cSpread) any(cSrvID) any(cTSince)]), ...
            'extractWindowedFeatures:schemaMismatch', ...
            'handoverManager.featureNames does not contain the expected columns.');

        % Discard the warm-up period (settle gating, see header)
        keepRows = fl(:, cTime) >= cfg.settleTime;
        fl = fl(keepRows, :);
        if isempty(fl)
            warning('extractWindowedFeatures:allSettled', ...
                'All rows for %s fall inside the %.2f s settle period; UE skipped.', ...
                m.UE.Name, cfg.settleTime);
            continue;
        end

        t = fl(:, cTime);
        label = double(m.ueLabel == "aerial");
        hoTimes = m.handoverTimes(:);
        hoTimes = hoTimes(hoTimes >= cfg.settleTime);

        % Per-gNB SINR snapshots, settle-filtered on their own clock so
        % this does not silently depend on sinrLog and featureLog having
        % been appended in lockstep.
        sl = m.sinrLog;
        if ~isempty(sl)
            sl = sl(sl(:,1) >= cfg.settleTime, :);
        end
        gnbIDs = [m.gNBs.ID];

        % Cell-crowding series, computed ONCE PER UE over the whole run and
        % then averaged inside each window. Computing it per window instead
        % would rescan the snapshot log for every one of the overlapping
        % 10 s windows at a 1 s stride, which at a 10 ms scan period is
        % quadratic in run length and dominated everything else.
        [crowd3, crowd6, crowdTop3] = ...
            crowdingSeries_(sl, gnbIDs, t, fl(:, cSrvID));

        % Per-UE scheduler and traffic sources
        ctx    = sched.ctx{sched.anchorIdx(k)};
        grants = sched.grants{sched.anchorIdx(k)};
        rnti = sched.rnti(k);
        ctx    = ctx(ctx(:, 2) == rnti, :);
        grants = grants(grants(:, 2) == rnti, :);
        traf = trafficLogs{k};                     % [t appTx appRx macTx macRx]

        % Window start times (deterministic grid anchored at first scan)
        tFirst = t(1); tLast = t(end);
        span = tLast - tFirst;
        if span < cfg.windowLen
            warning('extractWindowedFeatures:shortRun', ...
                ['Logged span (%.2f s) for %s is shorter than the %.2f s ' ...
                 'window; emitting one clipped window.'], ...
                span, m.UE.Name, cfg.windowLen);
            starts = tFirst;
            winLen = span;
        else
            starts = tFirst : cfg.windowStride : (tLast - cfg.windowLen);
            winLen = cfg.windowLen;
        end

        for s0 = starts
            s1 = s0 + winLen;
            in = t >= s0 & t <= s1;
            if ~any(in), continue; end

            tw   = t(in);
            serv = fl(in, cServ);
            maxN = fl(in, cMaxN);
            spr  = fl(in, cSpread);
            vis  = fl(in, cVis);
            srvID  = fl(in, cSrvID);
            tSince = fl(in, cTSince);

            hoIn = hoTimes(hoTimes >= s0 & hoTimes <= s1);
            if numel(hoIn) >= 2
                meanInterHO = mean(diff(hoIn));
            else
                meanInterHO = NaN;
            end

            % ---- CQI / MCS block (anchor-gNB scheduler logs) ----
            cin = ctx(ctx(:,1) >= s0 & ctx(:,1) <= s1, :);
            cqi = cin(~isnan(colOr_(cin, 3)), [1 3]);   % [t cqi]
            if isempty(cqi)
                cqiMean = NaN; cqiVar = NaN; cqiTrend = NaN;
            else
                cqiMean = mean(cqi(:,2));
                cqiVar  = var(cqi(:,2));
                if numel(unique(cqi(:,1))) >= 2
                    p = polyfit(cqi(:,1) - s0, cqi(:,2), 1);
                    cqiTrend = p(1);
                else
                    cqiTrend = NaN;
                end
            end
            gin = grants(grants(:,1) >= s0 & grants(:,1) <= s1, :);
            isDL = gin(:,3) == 0;
            isUL = gin(:,3) == 1;
            mdl = gin(isDL & ~isnan(colOr_(gin, 4)), 4);
            mul = gin(isUL & ~isnan(colOr_(gin, 4)), 4);
            [mcsDLmean, mcsDLvar] = moments_(mdl);
            [mcsULmean, mcsULvar] = moments_(mul);

            % ---- Traffic block (MAC counters, step interpolation) ----
            [ulVol, dlVol, burstCV, idleFrac, ulTrend, dlTrend] = ...
                trafficWindow_(traf, s0, s1);
            tot = ulVol + dlVol;
            if tot > 0
                asym = (dlVol - ulVol) / tot;
            else
                asym = NaN;
            end
            thr = tot * 8 / winLen;

            % ================= PHASE 5 BLOCKS =========================

            % ---- rank and CSI structure ----
            [riMean, riVar] = moments_(dropNaN_(colOr_(cin, 4)));
            riAll = dropNaN_(colOr_(cin, 4));
            if isempty(riAll)
                rankOneFrac = NaN;
            else
                rankOneFrac = mean(riAll == 1);
            end
            sbSpread = meanOrNaN_(dropNaN_(colOr_(cin, 6)));
            [ulMcsCtxMean, ulMcsCtxVar] = moments_(dropNaN_(colOr_(cin, 5)));

            % ---- resource consumption ----
            prbDLv = dropNaN_(subset_(colOr_(gin, 5), isDL));
            prbULv = dropNaN_(subset_(colOr_(gin, 5), isUL));
            prbDLmean = meanOrNaN_(prbDLv);
            prbULmean = meanOrNaN_(prbULv);
            prbDLsum  = sum(prbDLv);      % 0 when no DL grants: a true zero
            prbULsum  = sum(prbULv);
            grantRateDL = sum(isDL) / winLen;
            grantRateUL = sum(isUL) / winLen;
            layersMean  = meanOrNaN_(dropNaN_(colOr_(gin, 7)));
            prbTot = prbDLsum + prbULsum;
            if prbTot > 0
                specEff = tot * 8 / prbTot;
            else
                specEff = NaN;
            end

            % ---- reliability (retransmission fraction = residual BLER) ----
            retxDLv = dropNaN_(subset_(colOr_(gin, 6), isDL));
            retxULv = dropNaN_(subset_(colOr_(gin, 6), isUL));
            retxRateDL = meanOrNaN_(retxDLv);
            retxRateUL = meanOrNaN_(retxULv);
            retxAll    = dropNaN_(colOr_(gin, 6));
            retxRate   = meanOrNaN_(retxAll);

            % ---- timing advance ----
            taRows = cin(~isnan(colOr_(cin, 7)), :);
            if isempty(taRows)
                taMean = NaN; taVar = NaN; taTrend = NaN; taRange = NaN;
            else
                taV = taRows(:, 7);
                taMean = mean(taV);
                taVar  = var(taV);
                taTrend = slope_(taRows(:,1) - s0, taV);
                taRange = max(taV) - min(taV);
            end

            % ---- serving SINR dynamics ----
            servTrend = slope_(tw - s0, serv);
            servRange = rangeOrNaN_(serv);
            servIQR   = iqr_(serv);
            servMin   = minOrNaN_(serv);
            servMax   = maxOrNaN_(serv);
            servAC1   = autocorr1_(serv);
            servFade  = fadeRate_(tw, serv);

            % ---- cell geometry ----
            margin = serv - maxN;
            marginMean = meanOrNaN_(dropNaN_(margin));
            marginMin  = minOrNaN_(margin);
            maxNvar    = varOrNaN_(dropNaN_(maxN));
            sprVar     = varOrNaN_(dropNaN_(spr));
            sprTrend   = slope_(tw - s0, spr);
            visVar     = varOrNaN_(dropNaN_(vis));
            visMax     = maxOrNaN_(vis);
            visTrend   = slope_(tw - s0, vis);
            w3   = meanOrNaN_(dropNaN_(crowd3(in)));
            w6   = meanOrNaN_(dropNaN_(crowd6(in)));
            top3 = meanOrNaN_(dropNaN_(crowdTop3(in)));

            % ---- serving-cell history ----
            srvValid = srvID(~isnan(srvID));
            if isempty(srvValid)
                distinctCells = NaN; cellEntropy = NaN; pingPong = NaN;
            else
                u = unique(srvValid);
                distinctCells = numel(u);
                p = histcounts(srvValid, [u(:); max(u)+1]) / numel(srvValid);
                p = p(p > 0);
                cellEntropy = -sum(p .* log2(p));
                pingPong = pingPongCount_(srvValid);
            end
            hoRate = numel(hoIn) / winLen;
            tSinceMean = meanOrNaN_(dropNaN_(tSince));
            tSinceMin  = minOrNaN_(tSince);

            % ---- traffic extensions ----
            ulThr = ulVol * 8 / winLen;
            dlThr = dlVol * 8 / winLen;

            newRow = [ ...
                cfg.seed, m.UE.ID, label, s0, s1, ...
                mean(serv, 'omitnan'), var(serv, 0, 'omitnan'), ...
                mean(maxN, 'omitnan'), ...
                mean(fl(in, cMeanN), 'omitnan'), ...
                mean(spr,  'omitnan'), ...
                mean(vis,  'omitnan'), ...
                numel(hoIn), meanInterHO, ...
                cqiMean, cqiVar, cqiTrend, ...
                mcsDLmean, mcsDLvar, mcsULmean, mcsULvar, ...
                ulVol, dlVol, asym, burstCV, thr, ...
                ... % --- Phase 5 ---
                riMean, riVar, rankOneFrac, sbSpread, ...
                ulMcsCtxMean, ulMcsCtxVar, ...
                prbDLmean, prbULmean, prbDLsum, prbULsum, ...
                grantRateDL, grantRateUL, layersMean, specEff, ...
                retxRateDL, retxRateUL, retxRate, ...
                taMean, taVar, taTrend, taRange, ...
                servTrend, servRange, servIQR, servMin, servMax, ...
                servAC1, servFade, ...
                marginMean, marginMin, maxNvar, sprVar, sprTrend, ...
                visVar, visMax, visTrend, w3, w6, top3, ...
                distinctCells, cellEntropy, pingPong, hoRate, ...
                tSinceMean, tSinceMin, ...
                ulThr, dlThr, idleFrac, ulTrend, dlTrend];

            assert(numel(newRow) == numel(schema) - 1, ...
                'extractWindowedFeatures:rowWidthMismatch', ...
                ['Assembled %d numeric values for %d numeric schema ' ...
                 'columns. A column was added to phase5FeatureSchema ' ...
                 'without a matching value here (or vice versa); the CSV ' ...
                 'would be silently misaligned.'], ...
                numel(newRow), numel(schema) - 1);

            rows(end+1, :) = newRow; %#ok<AGROW>
        end
    end

    if isempty(rows)
        T = table('Size', [0 numel(schema)], ...
            'VariableTypes', [{'string'}, repmat({'double'}, 1, numel(schema)-1)], ...
            'VariableNames', schema);
        return;
    end

    % Deterministic row order: sort by ueID then window start.
    rows = sortrows(rows, [2 4]);

    T = [table(repmat(scen, size(rows,1), 1), 'VariableNames', schema(1)), ...
         array2table(rows, 'VariableNames', schema(2:end))];
end

%% ======================================================================
%  local functions
%  ======================================================================

function [mu, va] = moments_(x)
    if isempty(x)
        mu = NaN; va = NaN;
    else
        mu = mean(x); va = var(x);
    end
end

function c = colOr_(M, j)
%colOr_ Column J of M, or a NaN column when M is too narrow.
%   Lets this function accept the shorter Phase 4 scheduler logs (and the
%   synthetic fixtures in validateFeatureExtraction) without special
%   casing every call site: a missing column becomes an honest NaN
%   feature rather than an index error.
    if size(M, 2) >= j
        c = M(:, j);
    else
        c = nan(size(M, 1), 1);
    end
end

function y = subset_(x, mask)
    if isempty(x), y = x; return; end
    y = x(mask);
end

function y = dropNaN_(x)
    y = x(~isnan(x));
end

function v = meanOrNaN_(x)
    if isempty(x), v = NaN; else, v = mean(x); end
end

function v = varOrNaN_(x)
    if isempty(x), v = NaN; else, v = var(x); end
end

function v = minOrNaN_(x)
    x = dropNaN_(x);
    if isempty(x), v = NaN; else, v = min(x); end
end

function v = maxOrNaN_(x)
    x = dropNaN_(x);
    if isempty(x), v = NaN; else, v = max(x); end
end

function v = rangeOrNaN_(x)
    x = dropNaN_(x);
    if isempty(x), v = NaN; else, v = max(x) - min(x); end
end

function s = slope_(x, y)
%slope_ Least-squares slope of y against x, NaN when undetermined.
%   Requires at least two DISTINCT x values, matching the rule the Phase 4
%   CQI trend already used, so every trend column in the schema means the
%   same thing.
    ok = ~isnan(x) & ~isnan(y);
    x = x(ok); y = y(ok);
    if numel(x) < 2 || numel(unique(x)) < 2
        s = NaN;
        return;
    end
    p = polyfit(x, y, 1);
    s = p(1);
end

function v = iqr_(x)
%iqr_ Interquartile range without the Statistics toolbox.
%   Linear interpolation between order statistics (the default 'linear'
%   method), so the value matches quantile() for the same input.
    x = sort(dropNaN_(x));
    n = numel(x);
    if n < 2, v = NaN; return; end
    v = q_(x, n, 0.75) - q_(x, n, 0.25);
end

function v = q_(xs, n, p)
    h = (n - 1) * p + 1;
    lo = floor(h); hi = ceil(h);
    v = xs(lo) + (h - lo) * (xs(hi) - xs(lo));
end

function r = autocorr1_(y)
%autocorr1_ Lag-1 autocorrelation of a scan series.
%   A LOS-dominated link fades slowly, so consecutive scans are strongly
%   correlated; a richly scattered link decorrelates faster. This is the
%   legitimate operator-side proxy for the propagation regime, in place of
%   the simulator's LOS flag, which an operator cannot observe.
%   NaN for fewer than three samples or a constant series.
    y = dropNaN_(y);
    n = numel(y);
    if n < 3, r = NaN; return; end
    yc = y - mean(y);
    den = sum(yc.^2);
    if den <= 0, r = NaN; return; end
    r = sum(yc(1:end-1) .* yc(2:end)) / den;
end

function v = fadeRate_(t, y)
%fadeRate_ Mean absolute rate of change between consecutive scans (dB/s).
    ok = ~isnan(t) & ~isnan(y);
    t = t(ok); y = y(ok);
    if numel(t) < 2, v = NaN; return; end
    dt = diff(t(:));
    dy = abs(diff(y(:)));
    keep = dt > 0;                 % guard against duplicated timestamps
    if ~any(keep), v = NaN; return; end
    v = mean(dy(keep) ./ dt(keep));
end

function n = pingPongCount_(srvSeq)
%pingPongCount_ A -> B -> A serving-cell reversals inside the window.
%   The serving-cell sequence is first collapsed to its transitions, so a
%   cell held for many scans counts once. A reversal is any transition
%   triple whose first and third cells are equal. This is the
%   window-local companion to handoverManager's run-level ping-pong
%   statistic, which uses a minimum-time-of-stay rule instead.
    ch = srvSeq([true; diff(srvSeq(:)) ~= 0]);
    if numel(ch) < 3, n = 0; return; end
    n = sum(ch(1:end-2) == ch(3:end));
end

function [n3, n6, sp] = crowdingSeries_(sl, gnbIDs, t, srvID)
%crowdingSeries_ How many cells this UE hears at comparable strength.
%   Reads the per-scan per-cell SINR snapshot (handoverManager.sinrLog),
%   which up to Phase 4 was written and never read.
%
%   Returns three series aligned with the featureLog rows T:
%     N3, N6  count of NON-SERVING cells within 3 dB and 6 dB of the
%             serving cell at that scan
%     SP      SINR spread across the three strongest neighbours
%
%   An elevated UE clears the clutter that isolates ground cells, so it
%   hears many cells at once and at similar strength. That is the most
%   direct available measurement of the geometry the aerial label
%   describes, and it is what drives the handover instability the Phase 3
%   columns could only observe after the fact.
%
%   Each featureLog row is matched to the last snapshot at or before its
%   time. In practice both logs are appended by the same scan, so this is
%   an exact one-to-one match; the lookup is written generally so the two
%   logs are not REQUIRED to be in lockstep, and is vectorised with
%   discretize so the whole mapping costs one pass rather than a search
%   per row.
%
%   NaN where no snapshot is available (an archived run, a fixture that
%   does not populate sinrLog, or a scan whose serving cell has no column).

    n = numel(t);
    n3 = nan(n,1); n6 = nan(n,1); sp = nan(n,1);
    if isempty(sl) || size(sl, 2) < 2, return; end

    [uT, iu] = unique(sl(:,1), 'last');
    idx = discretize(t, [uT(:); Inf]);
    ok = ~isnan(idx);
    idx(ok) = iu(idx(ok));

    colByID = zeros(1, max(gnbIDs));
    colByID(gnbIDs) = 1:numel(gnbIDs);
    V = sl(:, 2:end);
    nCols = size(V, 2);

    for r = 1:n
        if isnan(idx(r)), continue; end
        gid = srvID(r);
        if isnan(gid) || gid < 1 || gid > numel(colByID) || colByID(gid) == 0
            continue;
        end
        c = colByID(gid);
        if c > nCols, continue; end

        v = V(idx(r), :);
        if isnan(v(c)), continue; end

        servV = v(c);
        nbr = v; nbr(c) = NaN;
        nbr = nbr(~isnan(nbr));
        if isempty(nbr)
            n3(r) = 0; n6(r) = 0;
            continue;
        end
        n3(r) = sum(nbr >= servV - 3);
        n6(r) = sum(nbr >= servV - 6);

        nb = sort(nbr, 'descend');
        nb = nb(1:min(3, numel(nb)));
        if numel(nb) >= 2
            sp(r) = max(nb) - min(nb);
        end
    end
end

function [ulVol, dlVol, burstCV, idleFrac, ulTrend, dlTrend] = ...
        trafficWindow_(traf, s0, s1)
%trafficWindow_ Byte deltas, burstiness, duty cycle and drift.
%   Cumulative counters are step-interpolated at the window edges (value
%   of the last sample at or before the edge), so the deltas are exact up
%   to one sample period and fully deterministic. Burstiness is the
%   coefficient of variation of the per-sample-interval TOTAL (UL+DL)
%   byte increments inside the window: near 0 for a steady stream, large
%   for on/off traffic, NaN when the window carried no traffic.
%
%   Phase 5 additions:
%     idleFrac - fraction of sample intervals with no bytes in either
%                direction. Burstiness measures how UNEVEN the traffic is;
%                the idle fraction measures how OFTEN it stops, which
%                separates a continuous uplink video stream (idle near 0)
%                from bursty app traffic even when both have similar CV.
%     ulTrend / dlTrend - least-squares slope of the per-interval byte
%                RATE (B/s) against time, so a stream ramping up or
%                tailing off inside the window is visible.
    ulVol = NaN; dlVol = NaN; burstCV = NaN;
    idleFrac = NaN; ulTrend = NaN; dlTrend = NaN;
    if isempty(traf), return; end

    tt = traf(:,1); macTx = traf(:,4); macRx = traf(:,5);
    ulVol = stepAt_(tt, macTx, s1) - stepAt_(tt, macTx, s0);
    dlVol = stepAt_(tt, macRx, s1) - stepAt_(tt, macRx, s0);

    in = tt >= s0 & tt <= s1;
    tIn = tt(in);
    ulIn = macTx(in); dlIn = macRx(in);
    incUL = diff(ulIn); incDL = diff(dlIn);
    inc = incUL + incDL;

    if isempty(inc) || mean(inc) == 0
        burstCV = NaN;
    else
        burstCV = std(inc) / mean(inc);
    end

    if isempty(inc)
        idleFrac = NaN;
    else
        idleFrac = mean(inc == 0);
    end

    if numel(tIn) >= 3
        dt = diff(tIn);
        mid = tIn(1:end-1) + dt/2;      % rate applies to the interval mid
        ok = dt > 0;
        if sum(ok) >= 2
            ulTrend = slope_(mid(ok) - s0, incUL(ok) ./ dt(ok));
            dlTrend = slope_(mid(ok) - s0, incDL(ok) ./ dt(ok));
        end
    end
end

function v = stepAt_(tt, y, tq)
    idx = find(tt <= tq, 1, 'last');
    if isempty(idx)
        v = 0;   % edge precedes the first sample: counters started at 0
    else
        v = y(idx);
    end
end
