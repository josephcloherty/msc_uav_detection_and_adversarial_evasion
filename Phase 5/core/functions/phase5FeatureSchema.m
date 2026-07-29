function schema = phase5FeatureSchema()
%phase5FeatureSchema The Phase 5 dataset column set (D5.2).
%
%   SCHEMA = phase5FeatureSchema() returns the ordered column list for the
%   Phase 5 labelled feature CSV. The Phase 4 schema is preserved as an
%   EXACT PREFIX (obtained by calling phase4FeatureSchema, which in turn
%   calls phase3FeatureSchema, never by copying names), and the Phase 5
%   columns are strictly appended. A Phase 3 CSV is a column-prefix of a
%   Phase 4 CSV, which is a column-prefix of a Phase 5 CSV, so any tooling
%   keyed to the earlier columns keeps working unchanged.
%
%   WHAT QUALIFIES AS A FEATURE
%   ---------------------------
%   Every column below is computable by a network operator from
%   measurements it already collects: per-cell uplink SRS SINR, handover
%   and serving-cell history, scheduler CSI reports and grants, HARQ
%   outcomes, timing advance, and MAC byte counters. Nothing here uses UE
%   position, velocity, altitude, or the simulator's LOS state.
%
%   The LOS flag is DELIBERATELY ABSENT. An operator cannot observe LOS
%   state - it is a latent property of the propagation environment, not a
%   reported quantity - and in this scenario set it is near-collinear with
%   the aerial label, because Table B-1 gives pLOS = 1 above 100 m in UMa.
%   Including it would leak ground truth and inflate every classifier
%   score in Phase 6. The observable consequences of LOS propagation are
%   captured instead, by cqiSubbandSpread_mean (frequency flatness),
%   servSINR_autocorr1 and servSINR_fadeRate_dBperS (fading dynamics), and
%   riMean / rankOne_frac (rank collapse). The LOS state IS recorded, in
%   the run diagnostics bundle, where it is available for analysis without
%   ever entering the training matrix.
%
%   APPENDED COLUMNS (all per UE per window, network-observable)
%   -----------------------------------------------------------
%
%   Rank and CSI structure. An airborne UE sees a near-free-space channel
%   with little scattering, so its reported rank collapses towards 1 and
%   its subband CQI flattens. Both are among the strongest published
%   discriminators and neither was captured before Phase 5, despite the
%   rank indicator already sitting unused in the scheduler context log.
%     ri_mean                 mean reported DL rank indicator
%     ri_var                  variance of the reported rank indicator
%     rankOne_frac            fraction of reports with RI == 1
%     cqiSubbandSpread_mean   mean across-subband CQI standard deviation
%     ulMcsCtx_mean           mean SRS-derived UL MCS estimate (gNB-side,
%                             not UE-falsifiable; distinct from the
%                             GRANTED UL MCS already in the Phase 4 block)
%     ulMcsCtx_var            variance of the same
%
%   Resource consumption. What the cell actually spends on this UE.
%     prbDL_mean, prbUL_mean  mean granted resource blocks per grant
%     prbDL_sum,  prbUL_sum   total granted resource blocks in the window
%     grantRateDL_perS        DL grants per second
%     grantRateUL_perS        UL grants per second
%     layers_mean             mean granted spatial layers
%     spectralEff_bpsPerPRB   (UL+DL bits) / (UL+DL granted PRBs); NaN
%                             when no PRBs were granted
%
%   Reliability. Retransmission fraction is a residual-BLER estimate and a
%   standard operator KPI. Aerial UEs, seeing many near-equal cells and
%   rapid geometry change, retransmit differently from static ground UEs.
%     retxRateDL              DL retransmission grants / all DL grants
%     retxRateUL              UL retransmission grants / all UL grants
%     retxRate                combined; NaN when no grants at all
%
%   Timing advance. The propagation-delay measurement, and the single best
%   operator-side proxy for distance and therefore for altitude once the
%   serving cell is known. NaN throughout when the installed release does
%   not surface it; see the deviations log and phase4SchedulerCheck.
%     ta_mean, ta_var         moments of the timing advance
%     ta_trend_perS           least-squares slope of TA vs time
%     ta_range                max minus min within the window
%
%   Serving-SINR dynamics. The Phase 3 block kept only the mean and
%   variance, which throws away the shape of the trajectory. A climb or a
%   descent is a monotone drift; a LOS-dominated link fades slowly and
%   shallowly, a scattered one quickly and deeply.
%     servSINR_trend_perS     least-squares slope of serving SINR (dB/s)
%     servSINR_range_dB       max minus min
%     servSINR_iqr_dB         interquartile range (outlier-robust spread)
%     servSINR_min_dB         minimum in the window
%     servSINR_max_dB         maximum in the window
%     servSINR_autocorr1      lag-1 autocorrelation of the scan series
%     servSINR_fadeRate_dBperS  mean |dSINR|/dt between consecutive scans
%
%   Cell geometry. An aerial UE is elevated above the clutter that
%   isolates ground cells, so it hears many cells at similar strength.
%   That shows up as a small serving-to-best-neighbour margin and a large
%   count of near-equal cells - the same physics that drives its handover
%   instability, measured directly rather than through its consequences.
%     servMinusBestNbr_mean_dB  mean (serving - best neighbour) margin
%     servMinusBestNbr_min_dB   worst margin in the window
%     nbrSINR_max_var_dB2       variance of the best-neighbour SINR
%     sinrSpread_var_dB2        variance of the across-cell SINR spread
%     sinrSpread_trend_perS     slope of the across-cell SINR spread
%     numAboveThr_var           variance of the visible-cell count
%     numAboveThr_max           maximum visible-cell count
%     numAboveThr_trend_perS    slope of the visible-cell count
%     nbrWithin3dB_mean         mean number of cells within 3 dB of the
%                               serving cell
%     nbrWithin6dB_mean         same at 6 dB
%     top3NbrSpread_mean_dB     mean spread across the three strongest
%                               neighbours
%
%   Serving-cell history. Beyond the Phase 3 handover count: how many
%   distinct cells served the UE, how evenly, and how often the serving
%   cell bounced back to a cell it had just left.
%     distinctServCells_win     distinct serving cells in the window
%     servCellEntropy           Shannon entropy (bits) of the fraction of
%                               scans spent on each serving cell
%     pingPongCount_win         A -> B -> A serving-cell reversals
%     hoRate_perS               handovers per second
%     timeSinceHO_mean_s        mean of the logged time-since-handover
%     timeSinceHO_min_s         minimum of the same
%
%   Traffic, extending the Phase 4 block. The Phase 4 columns give total
%   volume and one asymmetry ratio; these separate the directions, measure
%   duty cycle, and capture drift.
%     ulThr_bps, dlThr_bps      per-direction mean throughput
%     trafficIdle_frac          fraction of sample intervals with zero
%                               bytes in either direction
%     ulVol_trend_Bps           least-squares slope of the UL byte rate
%     dlVol_trend_Bps           least-squares slope of the DL byte rate
%
%   NaN SEMANTICS (unchanged in spirit from Phase 4): a NaN means the
%   window contained no observation of that kind - no CSI report, no
%   grant, no traffic, fewer than two samples for a slope or an
%   autocorrelation, or a quantity the installed release does not expose.
%   NaN is never used to mean zero. The CSV writer prints NaN literally.

    schema = [phase4FeatureSchema(), { ...
        ... % rank and CSI structure
        'ri_mean', ...
        'ri_var', ...
        'rankOne_frac', ...
        'cqiSubbandSpread_mean', ...
        'ulMcsCtx_mean', ...
        'ulMcsCtx_var', ...
        ... % resource consumption
        'prbDL_mean', ...
        'prbUL_mean', ...
        'prbDL_sum', ...
        'prbUL_sum', ...
        'grantRateDL_perS', ...
        'grantRateUL_perS', ...
        'layers_mean', ...
        'spectralEff_bpsPerPRB', ...
        ... % reliability
        'retxRateDL', ...
        'retxRateUL', ...
        'retxRate', ...
        ... % timing advance
        'ta_mean', ...
        'ta_var', ...
        'ta_trend_perS', ...
        'ta_range', ...
        ... % serving SINR dynamics
        'servSINR_trend_perS', ...
        'servSINR_range_dB', ...
        'servSINR_iqr_dB', ...
        'servSINR_min_dB', ...
        'servSINR_max_dB', ...
        'servSINR_autocorr1', ...
        'servSINR_fadeRate_dBperS', ...
        ... % cell geometry
        'servMinusBestNbr_mean_dB', ...
        'servMinusBestNbr_min_dB', ...
        'nbrSINR_max_var_dB2', ...
        'sinrSpread_var_dB2', ...
        'sinrSpread_trend_perS', ...
        'numAboveThr_var', ...
        'numAboveThr_max', ...
        'numAboveThr_trend_perS', ...
        'nbrWithin3dB_mean', ...
        'nbrWithin6dB_mean', ...
        'top3NbrSpread_mean_dB', ...
        ... % serving-cell history
        'distinctServCells_win', ...
        'servCellEntropy', ...
        'pingPongCount_win', ...
        'hoRate_perS', ...
        'timeSinceHO_mean_s', ...
        'timeSinceHO_min_s', ...
        ... % traffic
        'ulThr_bps', ...
        'dlThr_bps', ...
        'trafficIdle_frac', ...
        'ulVol_trend_Bps', ...
        'dlVol_trend_Bps'}];
end
