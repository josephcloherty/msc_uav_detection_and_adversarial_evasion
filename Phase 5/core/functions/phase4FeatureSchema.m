function schema = phase4FeatureSchema()
%phase4FeatureSchema The locked Phase 4 dataset column set (D4.2).
%
%   SCHEMA = phase4FeatureSchema() returns the ordered column list for the
%   Phase 4 labelled feature CSV. The Phase 3 schema is preserved as an
%   EXACT PREFIX (obtained by calling phase3FeatureSchema, the single
%   source of truth, never by copying names), and the Phase 4 columns are
%   strictly appended. A Phase 3 CSV is therefore a column-prefix of a
%   Phase 4 CSV, and any tooling keyed to the Phase 3 columns keeps
%   working. From here this expanded list is the locked schema that later
%   phases consume.
%
%   Appended columns (all per UE per 10 s window, network-observable):
%
%     CQI / MCS block. wbCQI is the UE-reported wideband DL CQI
%     (TS 38.214 clause 5.2.2.1, index 0-15) as logged by the custom
%     scheduler at the UE's anchor gNB; it is spoofable and flagged as
%     such for the Q3 threat model. The MCS columns are the gNB's own
%     link-adaptation output per granted TTI (TS 38.214 Tables 5.1.3.1
%     DL / 6.1.4 UL, index 0-28): DL MCS sits downstream of the reported
%     CQI (falsified CQI propagates into it), while UL MCS derives from
%     gNB-side SRS measurement and is not UE-falsifiable.
%       cqi_mean            mean wideband DL CQI over the window
%       cqi_var             variance of wideband DL CQI
%       cqi_trend_perS      least-squares slope of CQI vs time (CQI/s)
%       mcsDL_mean          mean granted DL MCS index
%       mcsDL_var           variance of granted DL MCS index
%       mcsUL_mean          mean granted UL MCS index
%       mcsUL_var           variance of granted UL MCS index
%
%     Traffic block, from the MAC byte counters (what crosses the radio
%     interface, i.e. what an operator meters):
%       ulVol_bytes         UL bytes sent by the UE inside the window
%       dlVol_bytes         DL bytes received by the UE inside the window
%       dlulAsym            (DL-UL)/(DL+UL), in [-1,1]; -1 is pure
%                           uplink (the video-streaming-drone signature),
%                           +1 pure downlink; NaN when no traffic
%       trafficBurstiness_cv  coefficient of variation (std/mean) of the
%                           per-sample-interval total byte increments;
%                           near 0 for a steady stream, large for bursty
%                           on/off traffic; NaN when no traffic
%       thr_mean_bps        mean total throughput over the window,
%                           (UL+DL bytes)*8/windowLen
%
%   NaN semantics: a NaN in the CQI/MCS block means no report or grant
%   fell inside the window; a NaN in dlulAsym/trafficBurstiness_cv means
%   zero traffic. The CSV writer prints NaN literally (unchanged).

    schema = [phase3FeatureSchema(), { ...
        'cqi_mean', ...
        'cqi_var', ...
        'cqi_trend_perS', ...
        'mcsDL_mean', ...
        'mcsDL_var', ...
        'mcsUL_mean', ...
        'mcsUL_var', ...
        'ulVol_bytes', ...
        'dlVol_bytes', ...
        'dlulAsym', ...
        'trafficBurstiness_cv', ...
        'thr_mean_bps'}];
end
