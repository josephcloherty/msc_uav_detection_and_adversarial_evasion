# Deviations log

**7 July 2026. Handover policy replaced by the TR 36.777 Table A.2.1-1 mobility chain.**

Decision. The instant A3 comparison inherited from the Fudan repo (per-scan decision on a 4-sample average with a 1 dB hysteresis and no time-to-trigger) is replaced as the default by the TS 36.331 measurement model with the baseline parameters that TR 36.777 Annex A.2.1 (Table A.2.1-1, verified in the source document) agreed for aerial mobility evaluations: L1 linear filtering over a 200 ms sliding window at the 10 ms measurement interval, L3 filtering with coefficient k = 1 (a = (1/2)^(k/4)), event A3 with a 2 dB offset held continuously for a 160 ms time-to-trigger with per-neighbour timers, and a 50 ms preparation plus 40 ms execution delay before the logical switch. The 1.22 dB measurement-error standard deviation is applied inside the decision chain from a stream seeded per UE from the run seed, and the ping-pong statistic now uses the table's 1 s minimum-time-of-stay definition. The legacy behaviour remains available via useTr36777Mobility = false.

Reason. Diagnostics from a 20 s UMa run showed uplink SINR saturating near 32 dB, leaving the 1 dB instant hysteresis below the fading-noise scale and producing five ping-pongs in six handovers; the plan calls for behaviour matching a real 5G network. Two documented substitutions: the measurement metric is uplink SRS SINR rather than the DL RSRP of the table (structural to this simulator), and the injected measurement error affects only the handover decisions, never the logged features or sinrLog, so the dataset feature definitions are unchanged. Radio link failure modelling (Qin/Qout, T310/N310) from the same table is not implemented.

**7 July 2026. Per-gNB SINR snapshot log added to the handover manager.**

Decision. handoverManager (Fudan-derived) gains an additive sinrLog property: one row per scan holding the timestamp and the per-gNB averaged SRS SINR vector already computed for the handover decision. Nothing reads it during the run; the diagnostics export and the replay plotting consume it afterwards.

Reason. The featureLog keeps only serving/max/mean aggregates, which was insufficient to diagnose the serving-cell anomalies found in the 20 s UMa run (the third cell's series had to be reconstructed algebraically, which only works with exactly three gNBs). Logging the full vector makes every link reviewable directly. The decision path of the manager is untouched.

**7 July 2026. Bug fix in the Phase 2 position recorder (spurious zero frame).**

Decision. positionRecorder.record now assigns the first snapshot directly instead of using XYZ(:, :, end+1) on an empty array. In MATLAB, size([], 3) is 1, so the first append wrote to the second slab and left the first as zeros, giving one more position frame than timestamps, a phantom first frame with every node at the origin, and a one-sample misalignment between times and positions in the replay.

Reason. Found by analysing an exported diagnostics file from a 20 s UMa run: posLog carried 1999 timestamps but 2000 frames, the first frame was all zeros, and per-frame speed estimates showed impossible jumps from the origin to the true positions. This, not the initial attach, was why replays opened with all UEs stacked in one place. Replays saved before the fix retain the artefact (the settle cull hides the zero frame but not the one-sample shift); re-running the scenario regenerates a clean log.

**7 July 2026. Geometric building blockage removed from the Phase 3 pipeline.**

Decision. The Phase 2 building-blockage add-on (the buildingChannel wrapper and its axis-aligned box intersection test, carried over from phase2_Network_SB.m) has been removed from phase3_Pipeline.m, along with the cfg.buildingsRaw and cfg.blockageDB fields in all three scenario scripts. LOS and NLOS behaviour is now produced entirely by the statistical models: the LOS-state draw from TR 36.777 Table B-1 / TR 38.901 Table 7.4.2-1 and the LOS- or NLOS-specific pathloss rows of Table B-2 / Table 7.4.1-1. The average building height parameter is unaffected; it belongs to the UMa-AV ZOD offset geometry (equation B.1.1-2), not to blockage.

Reason. Running a fixed geometric attenuation on top of models whose NLOS statistics already account for building obstruction double-counts the effect. The TR channel models are calibrated as complete descriptions of the propagation environment, so the deterministic add-on was removed rather than left switchable.

**7 July 2026. Progress reporting moved to an in-place waitbar window.**

Decision. The Phase 2 line-per-update console reporter in phase3_Pipeline.m is replaced by a waitbar figure that updates in place with the percentage, simulated time, wall time, and estimated time remaining; without a desktop session it falls back to the Phase 2 printed lines. The period is now min(simulationTime/40, 0.05) seconds of simulated time and a zero per cent update is issued immediately before the run starts, with the bar closed automatically on completion or error.

Reason. The Phase 2 formula scaled the period with the run length, so a 30 s Phase 3 run printed nothing until 0.75 s of simulated time had elapsed, which can be many minutes of wall time at Phase 3 link counts; the run appeared to hang. A single updating bar also keeps the command window clear for the handover messages, which would otherwise interleave with dozens of progress lines. The Phase 2 script is unchanged.

**7 July 2026. Settle-time gating of the feature dataset.**

Decision. A cfg.settleTime parameter (set to 1 s in all three scenario scripts) discards per-scan feature rows and handover events that occur before the cut-off, in extractWindowedFeatures, before windowing; windows are anchored at the first retained scan. The simulation itself is unchanged, so the raw logs still contain the full run and the replay tool marks the settle span as excluded.

Reason. UEs attach to their nearest gNB by distance before any SINR has been measured, so the first scans produce a burst of corrective handovers and serving-SINR values that do not represent steady operation; including them would contaminate the windowed handover counts and inter-handover intervals. Gating at the extraction stage keeps the exclusion reproducible and adjustable without re-running the simulation.

**6 July 2026. TR 36.777 aerial overlay parameters read from the source document.**

Decision. All aerial overlay values were taken from the embedded equations of the TR 36.777 source (.doc parts 1 and 2), not from secondary summaries: applicability heights from Annex B.1 (RMa-AV 10 m to 300 m, UMa-AV and UMi-AV 22.5 m to 300 m); LOS probability coefficients from Table B-1 (RMa-AV p1 = max(15021 log10(hUT) - 16053, 1000), d1 = max(1350.8 log10(hUT) - 1602, 18), 100 per cent LOS above 40 m; UMa-AV p1 = 4300 log10(hUT) - 3800, d1 = max(460 log10(hUT) - 700, 18), 100 per cent above 100 m; UMi-AV p1 = 233.98 log10(hUT) - 0.95, d1 = max(294.05 log10(hUT) - 432.94, 18)); pathloss formulas from Table B-2; shadow fading standard deviations from Table B-3; CDL scaling parameters from Tables B.1.1-1 and B.1.1-2; ZOD offset equations B.1.1-1 and B.1.1-2 with a zero offset in NLOS per Step 6. The gNB antenna heights follow Table B-1 Note 1 (35 m RMa, 25 m UMa, 10 m UMi).

Reason. The plan requires each parameter to be verified against the source rather than assumed, and the terrestrial baselines that Tables B-1 and B-2 modify (Tables 7.4.2-1 and 7.4.1-1 of TR 38.901) were checked in the provided 38901-j40 document at the same time. One detail worth recording: the UMa-AV NLOS pathloss expression states a validity of 10 m < hUT <= 100 m and d2D <= 4 km; above 100 m the LOS probability is 100 per cent, so the NLOS branch is not expected to be exercised there.

**6 July 2026. Alternative 1 implemented through nrCDLChannel with a custom profile rather than the built-in CDL-D profile.**

Decision. The CDL-D cluster table (TR 38.901 Table 7.7.1-4, hard-coded in buildAerialCDL.m exactly as published) is supplied to nrCDLChannel with DelayProfile set to Custom, and the three scalings of TR 36.777 Annex B.1.1 are applied numerically: delay scaling per clause 7.7.3, K-factor scaling with delay re-normalisation per clause 7.7.6, and angle scaling per clause 7.7.5.1 using the LOS-preserving variant (equation 7.7-6).

Reason. The built-in DelayProfile CDL-D does not expose per-cluster ZOD, which Step 5 of Annex B.1.1 requires in order to add the geometry-derived offset to the non-direct paths only. The numerical scalings reproduce what the built-in DelaySpread, KFactorScaling and AngleScaling properties implement, and the LOS-preserving variant is appropriate because Step 3 sets the desired mean angles to the actual LOS angles of the link.

**6 July 2026. ZOD offset not applied to the diffuse part of the first CDL-D cluster.**

Decision. The Step 5 offset is added to the Laplacian clusters 2 to 13 but not to the diffuse (Laplacian) part of cluster 1, which shares the specular ray's angles.

Reason. nrCDLChannel custom profiles model the first cluster's specular and diffuse parts with a single angle set split by KFactorFirstCluster. The diffuse part of cluster 1 sits 13.3 dB below the specular ray in CDL-D, so the resulting error is small; splitting the cluster into two entries was judged not worth the added complexity.

**6 July 2026. Angle scale factor solved per Annex A.5; per-cluster ray spreads scaled with the cluster angles.**

Decision. The clause 7.7.5.1 scale factor is not taken as a linear spread ratio but solved numerically per TR 38.901 Annex A.5 (equations A-5 and A-6): the smallest factor at which the circular angular spread of the LOS ray plus the scaled cluster offsets, at model powers, equals the desired Table B.1.1-1/-2 spread. The cluster centre angles are then scaled about the LOS direction (equation 7.7-6) and the per-cluster ray spreads (cASD, cASA, cZSD, cZSA) are multiplied by the same factor.

Reason. The Annex A.5 solve was checked against every CDL-D entry of Table 7.7.5.1-1 and reproduces the published factors exactly (for example ZOD spread 1 degree gives 0.4477), confirming it is the intended method; a linear ratio does not, because the dominant LOS ray makes the composite spread strongly nonlinear in the factor. Step 3 of Annex B.1.1 states that the angular scaling applies to ray angles, not only cluster centres, and scaling the cluster-wise spreads by the same factor achieves this within the nrCDLChannel custom-profile interface.

**6 July 2026. Correction: UMi-AV Alternative 1 is not CDL-D based.**

Decision. The earlier project documentation described the UMi-AV aerial fast fading as CDL-D based, matching the UMa-AV and RMa-AV approach. The TR 36.777 source (Annex B.1.1, final paragraph) instead specifies a fast fading model "based on the 'reverse' UMa scenario" in which "the fast fading model in Section 7.5 of [4] is reused with the angular spreads at the base station and UE interchanged". The UMi fork therefore implements the clause 7.5 cluster-generation model with the BS and UE angular spreads swapped (umi/buildUMiAVChannel.m), and the earlier CDL-D assumption is recorded here as incorrect.

Reason. Verified directly against the source text before implementation, as required by the plan. The interchange is applied literally: the drawn large-scale spreads (ASD with ASA, ZSD with ZSA) and the corresponding cluster-wise ray spreads are swapped, while every other UMi parameter (delay distribution, cluster powers, cluster counts, XPR, ZOD offset from Table 7.5-8) is reused unchanged.

**6 July 2026. UMi z-boundary set to 22.5 m, superseding the earlier 20 m working assumption.**

Decision. The UMi fork uses 22.5 m as the aerial overlay floor.

Reason. Annex B.1 of TR 36.777 states the UMi-AV applicability range as 22.5 m to 300 m, the same floor as UMa-AV. The earlier 20 m figure was a working assumption derived from low-density-urban building-height reasoning and is not spec-derived; it has not been retained.

**6 July 2026. Simplifications in the UMi clause 7.5 implementation.**

Decision. The clause 7.5 model in umi/buildUMiAVChannel.m draws the large-scale parameters independently (the Table 7.5-6 cross-correlation matrix and spatial autocorrelation are not applied), replaces the per-ray lognormal XPR of Step 9 with the scalar mu_XPR value (9 dB LOS, 8 dB NLOS) because nrCDLChannel accepts one XPR value, and linearly interpolates the Table 7.5-2 and 7.5-4 scaling constants for cluster counts that the tables do not list (after the minus 25 dB cluster removal).

Reason. This is a single-link channel builder inside a system-level simulation, not a full 38.901 drop; the omitted correlations shape joint statistics across links, which the current feature set does not exploit. These are deliberate simplifications of the spec-accurate model, not claims of full compliance. The LSP distributions themselves (Table 7.5-6 Part-1 UMi columns and Table 7.5-8, including the Release 19 updated values in the provided 38901-j40 document) were verified at source.

**6 July 2026. Static per-link LOS state and fast-fading geometry.**

Decision. The LOS state of each gNB-UE pair is drawn once at setup from the Table B-1 probability (seeded Threefry stream, one substream per link) and the CDL cluster geometry is computed from the initial node positions; only the pathloss is recomputed from live positions per packet, so a UE crossing the z-boundary switches pathloss model mid-run but keeps its setup-time fast fading.

Reason. nrCDLChannel objects are static for the run, matching the Phase 2 and Fudan repo design; re-drawing LOS or rebuilding channels mid-run would break both the toolbox interface and reproducibility. Recorded as a known simplification.

**6 July 2026. MathWorks helper and Fudan repo adaptations.**

Decision. tr36777ChannelModel.m is an adapted copy of the MathWorks helper hNRCustomChannelModel.m (Copyright 2022-2023 The MathWorks, Inc.): the fast-fading application path is retained verbatim and the pathloss computation is replaced by the height-switched TR 38.901 / TR 36.777 model, with the aerial branch restricted to links that have a UE at one end so that gNB-to-gNB interference paths always use the terrestrial model. phase3_Pipeline.m is adapted from the Fudan-derived phase2_Network_SB.m: the scenario is parameterised by a config struct, the flat CDL-C channel is replaced by createScenarioChannels, ground-truth labels come from an explicit per-UE flag rather than an initial-height heuristic, and the run ends with the windowed extraction and CSV export. The original helper and Phase 2 script are left untouched.

Reason. The Phase 2 pathloss model (flat nrPathLoss UMa for every link) cannot represent the aerial overlay, and the label heuristic would misclassify an aerial UE that starts below the boundary. Adapting copies rather than editing the originals keeps the Phase 2 baseline reproducible.

**6 July 2026. Channel seeding scheme changed from the Fudan convention.**

Decision. Channel object seeds are cfg.seed*1000 plus a unique per-link index, with the uplink and downlink objects of a pair sharing one seed. The Fudan scripts used 73 + (ueIdx - 1) for both directions.

Reason. The Fudan scheme gives a UE the same fading realisation towards every gNB, which is unphysical and could leak into the neighbour-SINR features; the per-link scheme keeps every link distinct while remaining fully determined by the run seed. The shared uplink/downlink seed retains the Fudan reciprocity convention.

**6 July 2026. Carrier frequency kept at 2.6 GHz for all three forks.**

Decision. All forks run at 2.6 GHz, carried over from Phase 2.

Reason. Dataset continuity across phases and comparability between forks. The TR 36.777 calibration assumptions used 2 GHz for UMa-AV and UMi-AV and 700 MHz for RMa-AV (Table C.1-1); the pathloss and LOS models remain valid at 2.6 GHz (RMa is specified up to 7 GHz), so this is a deliberate deviation from the calibration set-up, not from the models.

**6 July 2026. Terrestrial fast fading below the z-boundary.**

Decision. Terrestrial-band links use the built-in CDL-D (LOS) or CDL-C (NLOS) profile scaled to the scenario median delay spread from TR 38.901 Table 7.5-6 evaluated at the carrier frequency (values from the provided 38901-j40 document, which carries the Release 19 updates), instead of the full clause 7.5 stochastic model.

Reason. A pragmatic upgrade over the Phase 2 flat CDL-C at 100 ns that keeps the terrestrial side deterministic and cheap; the study's discriminative features concern the aerial overlay, and Table B-4 of TR 36.777 keeps terrestrial UEs on the standard TR 38.901 model in any case. Recorded as a simplification of the terrestrial baseline.

**6 July 2026. Shadow fading implemented but disabled by default.**

Decision. Table B-3 shadow fading (aerial bands) and the terrestrial TR 38.901 values are implemented in tr36777ShadowFadingStd.m and drawn once per link from the seeded stream, but cfg.enableShadowFading defaults to false in all three scenario scripts.

Reason. The first schema-locked datasets should isolate the deterministic geometry and overlay effects; enabling the lognormal term is a one-flag change and remains seed-reproducible when switched on.

**6 July 2026. Average building height for the UMa-AV ZOD offset set to 20 m.**

Decision. Equation B.1.1-2 needs the building height h under the rooftop reflection; cfg.avgBuildingHeight is set to 20 m in the UMa fork.

Reason. TR 36.777 does not fix h; 20 m is the customary UMa average rooftop assumption in TR 38.901 modelling and sits below the 22.5 m aerial floor, keeping the offset geometry consistent. Exposed in the scenario script so it can be revisited.

**6 July 2026. CSV writer prints fixed-format text rather than using writetable.**

Decision. writeFeatureCSV.m opens the file in binary mode and prints integers as integers and non-integers with a fixed six-decimal format, with NaN printed literally.

Reason. writetable float formatting varies across MATLAB versions and platforms and would break the byte-identical regeneration required by the D3.1 exit criterion.
