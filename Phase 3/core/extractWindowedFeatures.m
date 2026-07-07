function T = extractWindowedFeatures(managers, cfg)
%extractWindowedFeatures Per-UE sliding-window feature extraction (D3.1).
%
%   T = extractWindowedFeatures(MANAGERS, CFG) converts the per-scan
%   featureLog rows accumulated by each handoverManager into windowed
%   feature rows, one row per UE per window position. The window slides
%   along the scan-time axis; every feature is computed only from
%   network-side observables (per-gNB SRS SINR and handover events), never
%   from UE position or identity.
%
%   MANAGERS is the cell array of handoverManager objects from the
%   scenario script. CFG is the scenario config struct; the fields used
%   here are:
%       cfg.scenario      - "UMa" | "RMa" | "UMi" (written into every row)
%       cfg.seed          - RNG seed of the run (written into every row)
%       cfg.windowLen     - window length in seconds (default 10)
%       cfg.windowStride  - window stride in seconds (default 1)
%       cfg.settleTime    - warm-up cut-off in seconds (default 0). Scan
%                           rows and handover events before this time are
%                           discarded: the initial attach is by nearest
%                           distance rather than measured SINR, so the
%                           first scans produce a burst of corrective
%                           handovers and unrepresentative features.
%                           Windows are anchored at the first retained
%                           scan, so the settle period never leaks into
%                           the dataset.
%
%   The output T is a MATLAB table whose column set is the LOCKED Phase 3
%   schema. Do not add, remove, rename, or reorder columns; later phases
%   consume this schema as-is. Column definitions:
%
%       scenario          string  scenario identifier: UMa, RMa, or UMi
%       seed              double  RNG seed used for the run
%       ueID              double  simulator node ID of the UE
%       label             double  ground truth: 0 terrestrial, 1 aerial
%       winStart_s        double  window start time (s, simulation clock)
%       winEnd_s          double  window end time (s)
%       servSINR_mean_dB  double  mean serving-cell SINR over the window
%       servSINR_var_dB2  double  variance of serving-cell SINR
%       nbrSINR_max_mean_dB   double  window mean of per-scan MAX neighbour SINR
%       nbrSINR_mean_mean_dB  double  window mean of per-scan MEAN neighbour SINR
%       sinrSpread_mean_dB    double  window mean of per-scan SINR spread
%                                     (max minus min over all gNBs)
%       numAboveThr_mean  double  window mean of the per-scan count of
%                                 gNBs whose averaged SINR exceeds the
%                                 visibility threshold
%       hoCount_win       double  handovers executed inside the window
%       meanInterHO_s     double  mean interval between consecutive
%                                 handovers inside the window (NaN when
%                                 fewer than two handovers fall in it)
%
%   Windowing rules (deterministic, so a fixed seed regenerates the CSV
%   byte-for-byte):
%     - Windows start at the first scan time of each UE and advance by
%       cfg.windowStride; a window is emitted only if it fits entirely
%       inside the logged span [tFirst, tLast].
%     - If the logged span is shorter than cfg.windowLen, a single clipped
%       window covering the whole span is emitted and a warning is issued,
%       so short smoke-test runs still produce schema-valid output.
%
%   The per-scan feature columns consumed here are defined by
%   handoverManager.featureNames; the column indices below are asserted
%   against that list so a silent reorder upstream cannot corrupt the
%   dataset.

    if ~isfield(cfg, 'windowLen'),    cfg.windowLen = 10;   end
    if ~isfield(cfg, 'windowStride'), cfg.windowStride = 1; end
    if ~isfield(cfg, 'settleTime'),   cfg.settleTime = 0;   end

    schema = phase3FeatureSchema();
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

            rows(end+1, :) = [ ...
                cfg.seed, m.UE.ID, label, s0, s1, ...
                mean(serv, 'omitnan'), var(serv, 0, 'omitnan'), ...
                mean(fl(in, cMaxN),  'omitnan'), ...
                mean(fl(in, cMeanN), 'omitnan'), ...
                mean(fl(in, cSpread),'omitnan'), ...
                mean(fl(in, cVis),   'omitnan'), ...
                numel(hoIn), meanInterHO]; %#ok<AGROW>
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
