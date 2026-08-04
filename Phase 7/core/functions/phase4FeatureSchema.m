function schema = phase4FeatureSchema()
%phase4FeatureSchema The locked Phase 4 dataset column set.
%
%   SCHEMA = phase4FeatureSchema() returns the ordered column list, built by
%   calling phase3FeatureSchema and appending, so Phase 3 stays an exact
%   prefix.
%
%   Appended columns, all per UE per 10 s window.
%
%   CQI and MCS. wbCQI is the UE-reported wideband DL CQI (TS 38.214 clause
%   5.2.2.1, index 0-15), which is spoofable and flagged as such for the Q3
%   threat model. The MCS columns are the gNB's own link-adaptation output
%   per granted TTI (TS 38.214 Tables 5.1.3.1 DL / 6.1.4 UL, index 0-28), and
%   only the UL side is safe from a falsified CQI.
%     cqi_mean            mean wideband DL CQI over the window
%     cqi_var             variance of wideband DL CQI
%     cqi_trend_perS      least-squares slope of CQI vs time (CQI/s)
%     mcsDL_mean          mean granted DL MCS index
%     mcsDL_var           variance of granted DL MCS index
%     mcsUL_mean          mean granted UL MCS index
%     mcsUL_var           variance of granted UL MCS index
%
%   Traffic, from the MAC byte counters, which is what an operator meters:
%     ulVol_bytes         UL bytes sent by the UE inside the window
%     dlVol_bytes         DL bytes received by the UE inside the window
%     dlulAsym            (DL-UL)/(DL+UL); -1 is pure uplink, the
%                         video-streaming-drone signature
%     trafficBurstiness_cv  std/mean of the per-interval byte increments,
%                         near 0 for a steady stream
%     thr_mean_bps        mean total throughput over the window
%
%   A NaN means no report, grant or traffic fell inside the window.

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
