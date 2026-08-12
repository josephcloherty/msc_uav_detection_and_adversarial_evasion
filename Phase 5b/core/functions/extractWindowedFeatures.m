function T = extractWindowedFeatures(managers, cfg, sched, trafficLogs)
%extractWindowedFeatures Per-UE sliding-window feature extraction.
%
%   T = extractWindowedFeatures(MANAGERS, CFG, SCHED, TRAFFICLOGS) turns the
%   per-scan handover logs, the per-gNB scheduler logs and the traffic byte
%   series into one feature row per UE per window position.
%
%   Every feature comes from network-side observables only, never from UE
%   position, velocity, altitude, identity or the simulator's LOS state.
%   Windowing rules, settle gating and column definitions are unchanged from
%   Phase 4; phase5FeatureSchema holds the full column list.
%
%   SCHED wires the scheduler logs to UEs:
%     sched.ctx       one ctxLog matrix per gNB, from
%                     cqiLoggingScheduler.getLogs(); a shorter Phase 4 log
%                     is accepted and the new features come out NaN
%     sched.grants    one grantLog matrix per gNB, same tolerance
%     sched.anchorIdx each UE's anchor gNB, which is where its CQI, grants
%                     and traffic live because the logical handover model
%                     never moves the data link
%     sched.rnti      each UE's connection index at its anchor gNB, which is
%                     NOT the UE.ID + cfg.rntiOffset the managers use for
%                     SRS events
%
%   Getting sched.rnti wrong empties the whole CQI and MCS block at five and
%   seven gNBs; the two conventions only coincide on small layouts.
%
%   TRAFFICLOGS holds one matrix per UE of cumulative byte counters at 0.1 s
%   spacing, differenced at the window edges here. The cell-geometry block
%   also reads MANAGERS{k}.sinrLog.
%
%   Windows are anchored at the first retained scan. A NaN means no
%   observation of that kind in that window; a genuine zero is written as 0.

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

        % Filtered on their own clock, so this does not depend on the two
        % logs being appended in lockstep.
        sl = m.sinrLog;
        if ~isempty(sl)
            sl = sl(sl(:,1) >= cfg.settleTime, :);
        end
        gnbIDs = [m.gNBs.ID];

        % Once per UE then averaged per window; per-window would be
        % quadratic in run length.
        [crowd3, crowd6, crowdTop3] = ...
            crowdingSeries_(sl, gnbIDs, t, fl(:, cSrvID));

        ctx    = sched.ctx{sched.anchorIdx(k)};
        grants = sched.grants{sched.anchorIdx(k)};
        rnti = sched.rnti(k);
        ctx    = ctx(ctx(:, 2) == rnti, :);
        grants = grants(grants(:, 2) == rnti, :);
        traf = trafficLogs{k};                     % [t appTx appRx macTx macRx]

        % Deterministic grid anchored at the first scan.
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

            % CQI and MCS from the anchor gNB's scheduler logs.
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

            [ulVol, dlVol, burstCV, idleFrac, ulTrend, dlTrend] = ...
                trafficWindow_(traf, s0, s1);
            tot = ulVol + dlVol;
            if tot > 0
                asym = (dlVol - ulVol) / tot;
            else
                asym = NaN;
            end
            thr = tot * 8 / winLen;


            [riMean, riVar] = moments_(dropNaN_(colOr_(cin, 4)));
            riAll = dropNaN_(colOr_(cin, 4));
            if isempty(riAll)
                rankOneFrac = NaN;
            else
                rankOneFrac = mean(riAll == 1);
            end
            sbSpread = meanOrNaN_(dropNaN_(colOr_(cin, 6)));
            [ulMcsCtxMean, ulMcsCtxVar] = moments_(dropNaN_(colOr_(cin, 5)));

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

            % The retransmission fraction is residual BLER.
            retxDLv = dropNaN_(subset_(colOr_(gin, 6), isDL));
            retxULv = dropNaN_(subset_(colOr_(gin, 6), isUL));
            retxRateDL = meanOrNaN_(retxDLv);
            retxRateUL = meanOrNaN_(retxULv);
            retxAll    = dropNaN_(colOr_(gin, 6));
            retxRate   = meanOrNaN_(retxAll);

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

            servTrend = slope_(tw - s0, serv);
            servRange = rangeOrNaN_(serv);
            servIQR   = iqr_(serv);
            servMin   = minOrNaN_(serv);
            servMax   = maxOrNaN_(serv);
            servAC1   = autocorr1_(serv);
            servFade  = fadeRate_(tw, serv);

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

    rows = sortrows(rows, [2 4]);   % deterministic: ueID then window start

    T = [table(repmat(scen, size(rows,1), 1), 'VariableNames', schema(1)), ...
         array2table(rows, 'VariableNames', schema(2:end))];
end

function [mu, va] = moments_(x)
    if isempty(x)
        mu = NaN; va = NaN;
    else
        mu = mean(x); va = var(x);
    end
end

function c = colOr_(M, j)
%colOr_ Column J of M, or a NaN column when M is too narrow.
%   Lets the shorter scheduler logs and the synthetic test fixtures through
%   without special-casing every call site.
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
%   Needs two distinct x values, the same rule the Phase 4 CQI trend used,
%   so every trend column means the same thing.
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
%   Uses linear interpolation between order statistics, so it matches
%   quantile() for the same input.
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
%   A LOS-dominated link fades slowly and a scattered one decorrelates
%   faster, so this stands in for the unobservable LOS flag. NaN for fewer
%   than three samples or a constant series.
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
%   Collapses the sequence to its transitions first, so a cell held for many
%   scans counts once. The run-level statistic in handoverManager uses a
%   minimum-time-of-stay rule instead.
    ch = srvSeq([true; diff(srvSeq(:)) ~= 0]);
    if numel(ch) < 3, n = 0; return; end
    n = sum(ch(1:end-2) == ch(3:end));
end

function [n3, n6, sp] = crowdingSeries_(sl, gnbIDs, t, srvID)
%crowdingSeries_ How many cells this UE hears at comparable strength.
%   Reads handoverManager.sinrLog and returns three series aligned with T:
%     N3, N6  non-serving cells within 3 dB and 6 dB of the serving cell
%     SP      SINR spread across the three strongest neighbours
%
%   An elevated UE clears the clutter that isolates ground cells, so it hears
%   many cells at once and at similar strength. Each row is matched to the
%   last snapshot at or before its time; NaN where none is available.

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
%   Step-interpolates the cumulative counters at the window edges, so the
%   deltas are exact to one sample period. Burstiness is the coefficient of
%   variation of the per-interval UL+DL increments, near 0 for a steady
%   stream and large for on/off traffic.
%
%     idleFrac  fraction of intervals with no bytes either way, which
%               separates a steady uplink stream from bursty app traffic
%               even when both have a similar CV
%     ulTrend / dlTrend  slope of the per-interval byte rate against time
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
