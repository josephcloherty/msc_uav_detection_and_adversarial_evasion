function T = extractWindowedFeatures(managers, cfg, sched, sampler)
%extractWindowedFeatures Per-UE sliding-window feature extraction (D4.2).
%
%   T = extractWindowedFeatures(MANAGERS, CFG, SCHED, SAMPLER) converts
%   the per-scan featureLog rows accumulated by each handoverManager,
%   the CQI/MCS logs collected by the per-gNB cqiLoggingScheduler
%   instances, and the trafficSampler byte series into windowed feature
%   rows, one row per UE per window position. Every feature is computed
%   only from network-side observables (per-gNB SRS SINR, handover
%   events, scheduler CQI/MCS logs, MAC byte counters), never from UE
%   position or identity.
%
%   This is the Phase 4 extension of the Phase 3 function: the Phase 3
%   windowing rules, settle gating, column definitions and determinism
%   guarantees are UNCHANGED, and the Phase 3 columns are computed by the
%   same code as before. The new inputs are:
%
%   SCHED is a struct wiring the scheduler logs to UEs:
%       sched.logs      - cell array, one cqiLoggingScheduler per gNB
%       sched.anchorIdx - 1 x numUE, index (into sched.logs) of each UE's
%                         ANCHOR gNB: the cell that holds its physical
%                         data link for the whole run. Under the logical
%                         handover model (see the Phase 3 deviations log)
%                         the data link never moves, so the anchor's
%                         scheduler is where this UE's CQI reports,
%                         grants, and traffic live. In a real network
%                         these observables would follow the serving
%                         cell; here they follow the anchor. Recorded as
%                         a Phase 4 deviations entry.
%       sched.rnti      - 1 x numUE, the RNTI identifying each UE in the
%                         scheduler logs (UE.ID + cfg.rntiOffset, the
%                         same convention the handover managers use for
%                         SRS events; verified empirically by
%                         tools/rntiOffsetCalculator.m and asserted in
%                         phase4SchedulerCheck.m).
%
%   SAMPLER is the trafficSampler object (cumulative per-UE byte
%   counters at 0.1 s spacing; differenced at window edges here).
%
%   The output T is a MATLAB table whose column set is the LOCKED Phase 4
%   schema (phase4FeatureSchema): the Phase 3 columns as an exact prefix,
%   then the CQI/MCS and traffic columns. Column definitions live in the
%   two schema functions.
%
%   Windowed CQI/MCS features (per UE, from the anchor gNB's logs):
%     cqi_mean/cqi_var    - moments of the wideband DL CQI snapshots in
%                           the window
%     cqi_trend_perS      - least-squares slope of CQI vs time; the
%                           trend feature from the phased plan (a climb
%                           or descent shows up as a monotone CQI drift)
%     mcsDL_mean/var      - moments of the granted DL MCS indices
%     mcsUL_mean/var      - moments of the granted UL MCS indices
%
%   Windowed traffic features (per UE, MAC counters, cumulative values
%   step-interpolated at the window edges):
%     ulVol_bytes/dlVol_bytes - byte deltas across the window
%     dlulAsym            - (DL-UL)/(DL+UL); NaN when no traffic
%     trafficBurstiness_cv- std/mean of per-interval total increments
%     thr_mean_bps        - (UL+DL)*8/windowLen
%
%   Settle gating: windows are anchored at the first retained scan (as in
%   Phase 3), so scheduler and traffic rows in the settle span never fall
%   inside any window. Traffic deltas difference cumulative counters at
%   the window edges, so pre-window accumulation cancels by construction.
%
%   Determinism: all new features are deterministic functions of the run
%   logs; polyfit and the step interpolation introduce no randomness, so
%   the fixed-seed byte-identical regeneration contract carries over.

    if ~isfield(cfg, 'windowLen'),    cfg.windowLen = 10;   end
    if ~isfield(cfg, 'windowStride'), cfg.windowStride = 1; end
    if ~isfield(cfg, 'settleTime'),   cfg.settleTime = 0;   end

    schema = phase4FeatureSchema();
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
        assert(all([any(cTime) any(cServ) any(cVis) any(cMaxN) ...
            any(cMeanN) any(cSpread)]), ...
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

        % Per-UE scheduler and traffic sources (Phase 4)
        [ctx, grants] = sched.logs{sched.anchorIdx(k)}.getLogs();
        rnti = sched.rnti(k);
        ctx    = ctx(ctx(:, 2) == rnti, :);        % [t rnti cqi ri ulMcsCtx]
        grants = grants(grants(:, 2) == rnti, :);  % [t rnti dir mcs nRB]
        traf = sampler.getLog(k);                  % [t appTx appRx macTx macRx]

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

            serv = fl(in, cServ);
            hoIn = hoTimes(hoTimes >= s0 & hoTimes <= s1);
            if numel(hoIn) >= 2
                meanInterHO = mean(diff(hoIn));
            else
                meanInterHO = NaN;
            end

            % ---- CQI / MCS block (anchor-gNB scheduler logs) ----
            cin = ctx(ctx(:,1) >= s0 & ctx(:,1) <= s1, :);
            cqi = cin(~isnan(cin(:,3)), [1 3]);        % [t cqi]
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
            mdl = gin(gin(:,3) == 0 & ~isnan(gin(:,4)), 4);
            mul = gin(gin(:,3) == 1 & ~isnan(gin(:,4)), 4);
            [mcsDLmean, mcsDLvar] = moments_(mdl);
            [mcsULmean, mcsULvar] = moments_(mul);

            % ---- Traffic block (MAC counters, step interpolation) ----
            [ulVol, dlVol, burstCV] = trafficWindow_(traf, s0, s1);
            tot = ulVol + dlVol;
            if tot > 0
                asym = (dlVol - ulVol) / tot;
            else
                asym = NaN;
            end
            thr = tot * 8 / winLen;

            rows(end+1, :) = [ ...
                cfg.seed, m.UE.ID, label, s0, s1, ...
                mean(serv, 'omitnan'), var(serv, 0, 'omitnan'), ...
                mean(fl(in, cMaxN),  'omitnan'), ...
                mean(fl(in, cMeanN), 'omitnan'), ...
                mean(fl(in, cSpread),'omitnan'), ...
                mean(fl(in, cVis),   'omitnan'), ...
                numel(hoIn), meanInterHO, ...
                cqiMean, cqiVar, cqiTrend, ...
                mcsDLmean, mcsDLvar, mcsULmean, mcsULvar, ...
                ulVol, dlVol, asym, burstCV, thr]; %#ok<AGROW>
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

%% local functions
function [mu, va] = moments_(x)
    if isempty(x)
        mu = NaN; va = NaN;
    else
        mu = mean(x); va = var(x);
    end
end

function [ulVol, dlVol, burstCV] = trafficWindow_(traf, s0, s1)
%trafficWindow_ Byte deltas and burstiness from cumulative MAC counters.
%   Cumulative counters are step-interpolated at the window edges (value
%   of the last sample at or before the edge), so the deltas are exact up
%   to one sample period and fully deterministic. Burstiness is the
%   coefficient of variation of the per-sample-interval TOTAL (UL+DL)
%   byte increments inside the window: near 0 for a steady stream, large
%   for on/off traffic, NaN when the window carried no traffic.
    if isempty(traf)
        ulVol = NaN; dlVol = NaN; burstCV = NaN;
        return;
    end
    tt = traf(:,1); macTx = traf(:,4); macRx = traf(:,5);
    ulVol = stepAt_(tt, macTx, s1) - stepAt_(tt, macTx, s0);
    dlVol = stepAt_(tt, macRx, s1) - stepAt_(tt, macRx, s0);

    in = tt >= s0 & tt <= s1;
    inc = diff(macTx(in) + macRx(in));   % per-interval total increments
    if isempty(inc) || mean(inc) == 0
        burstCV = NaN;
    else
        burstCV = std(inc) / mean(inc);
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
