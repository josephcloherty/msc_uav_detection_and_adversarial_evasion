function schema = phase5bFeatureSchema()
%phase5bFeatureSchema The Phase 5b dataset column set.
%
%   SCHEMA = phase5bFeatureSchema() returns the ordered column list for the
%   labelled feature CSV, built by calling phase5FeatureSchema and appending,
%   so Phase 3, Phase 4 and Phase 5 all stay exact prefixes and an existing
%   Phase 5 file is a valid truncation of a Phase 5b one.
%
%   Phase 5b closes the gap recorded in the Phase 5 logbook on 8 August:
%   RSSI, RSRP and RSRQ were overlooked when the windowed feature block was
%   written and could not be recovered from the saved logs, because SINR is a
%   ratio and no absolute power figure was ever captured. phase5b_PowerTap
%   taps the uplink packet path for that level and handoverManager derives
%   the three per SRS event; this block is their windowed summary.
%
%   All three are uplink SRS quantities measured at the gNB, not downlink UE
%   reports, so they stay operator-side and cannot be falsified by the UE.
%   The per-resource-element normalisation is a fixed offset, so the columns
%   are monotone in the TS 38.215 definitions.
%
%   Appended columns, all per UE per window, taken from the serving cell:
%
%     rsrp_mean_dBm, rsrp_var_dB2      level and its spread
%     rsrp_min_dBm,  rsrp_max_dBm      extremes in the window
%     rsrp_trend_dBperS                least-squares slope against time
%
%     rssi_mean_dBm, rssi_var_dB2      total wideband received power
%     rssi_min_dBm,  rssi_max_dBm
%     rssi_trend_dBperS
%
%     rsrq_mean_dB,  rsrq_var_dB2      quality ratio, RSRP against RSSI
%     rsrq_min_dB,   rsrq_max_dB
%     rsrq_trend_dBperS
%
%   A NaN means the window held no observation of that kind, never zero. Every
%   column is NaN throughout when the run carried no power tap.

    schema = [phase5FeatureSchema(), { ...
        ... % reference signal received power
        'rsrp_mean_dBm', ...
        'rsrp_var_dB2', ...
        'rsrp_min_dBm', ...
        'rsrp_max_dBm', ...
        'rsrp_trend_dBperS', ...
        ... % received signal strength indicator
        'rssi_mean_dBm', ...
        'rssi_var_dB2', ...
        'rssi_min_dBm', ...
        'rssi_max_dBm', ...
        'rssi_trend_dBperS', ...
        ... % reference signal received quality
        'rsrq_mean_dB', ...
        'rsrq_var_dB2', ...
        'rsrq_min_dB', ...
        'rsrq_max_dB', ...
        'rsrq_trend_dBperS'}];
end
