# Deviations log

**20 July 2026. R2024b custom scheduler method signature differs from the current documentation.**

Decision. The first phase4SchedulerCheck run on R2024b showed that nrScheduler invokes the overridable methods as scheduleNewTransmissionsDL(obj, timeResource, frequencyAllocationBitmap, schedulingInfo) (assignDLResourceTTI, line 2054), not with the single schedulingInfo argument the current online reference describes. The cqiLoggingScheduler overrides were rewritten to accept varargin and forward it unchanged to the superclass call, so the class tracks whichever signature the installed release uses; only the first output, the grant list, is read, and through the existing defensive field probing.

Reason. The plan anticipated exactly this class of mismatch, which is why the check script gates first use: the custom scheduler documentation available online describes a later release than R2024b. The varargin form removes the dependency on the argument list entirely rather than pinning the R2024b signature, so the same class survives a future toolbox upgrade without edits.

**20 July 2026. Per-UE CQI and MCS logging via a delegating custom scheduler.**

Decision. Each gNB receives its own instance of cqiLoggingScheduler, a subclass of nrScheduler plugged in with configureScheduler before any UE connects (an ordering the toolbox requires). Both protected scheduling methods call the base-class implementations of scheduleNewTransmissionsDL and scheduleNewTransmissionsUL and only then record two logs: a UE-context snapshot at most every 5 ms holding the wideband DL CQI (the per-RB vector collapsed by rounded mean), the rank indicator, and the MCS index the gNB derives itself from SRS for the uplink; and one row per scheduling grant holding direction, MCS index and RB count. All context field access is written defensively so an absent field yields NaN rather than an error. First use is gated by phase4SchedulerCheck.m, which confirms on R2024b that the custom scheduler route of the reference example works, that superclass delegation returns valid grants, that CQI lies in 0 to 15 and MCS in 0 to 28 per TS 38.214, that the scheduler-log RNTIs match the UE ID plus offset convention the handover managers use, and that the public statistics() trees still expose no native CQI or MCS time series on R2024b.

Reason. Delegating the decisions to the stock scheduler keeps Phase 4 radio behaviour identical to Phase 3, so the new columns extend the dataset without perturbing the existing SINR and handover features. The no-native-CQI-logging conclusion (D1.2) was reached against R2026a documentation, and the plan requires the R2024b re-check to be run and logged before the class is trusted. Logging both the UE-reported CQI and the gNB-side SRS-derived uplink estimate keeps the spoofable and non-spoofable quantities separable: under the Q3 threat model falsified CQI propagates into granted DL MCS, while the uplink estimate is made by the gNB and cannot be falsified by the UE.

**20 July 2026. Per-class traffic profiles replace the class-identical constant streams.**

Decision. The Phase 3 configuration gave every UE identical 1 Mbps constant uplink and downlink streams. Phase 4 assigns per-class profiles from the scenario config: aerial UEs carry a steady 4 Mbps uplink stream with 1250 byte packets (a video-streaming drone, within the 2 to 6 Mbps live-video range reported in the LTE UAV measurement literature) and the TR 36.777 command and control model on the downlink, verified against the source document ("C&C: 60-100 kbps for UL/DL", packets of 1250 bytes arriving periodically every 100 ms; 100 kbps at 1250 bytes reproduces that period exactly). Terrestrial UEs carry a downlink-heavy bursty profile (2 Mbps in 1 s bursts every 3 s downlink, 200 kbps request bursts uplink). All On and Off periods are fixed scalars, so no traffic randomness enters the run and the byte-reproducibility contract holds.

Reason. This deliberately supersedes the earlier working principle that traffic profiles must remain identical across classes. That principle protected the RF and mobility features from application-fingerprint confounds while they were the only features under study; Phase 4 promotes traffic volume, burstiness, asymmetry and throughput into the operator-observable feature set itself, as the phased plan specifies, so the classes must now differ in traffic by design. The confound is managed rather than removed: the RF and mobility feature definitions are unchanged, the traffic features occupy separate columns so their contribution can be isolated in the Phase 6 analysis, and traffic reshaping is itself a Q3 evasion action whose cost the Phase 7 agent will quantify.

**20 July 2026. CQI, MCS and traffic observables follow the anchor gNB.**

Decision. Each UE's CQI reports, scheduling grants and traffic bytes are read from the gNB it attached to at setup (its anchor), for the whole run, regardless of logical handovers. The pipeline records the anchor index and the scheduler-log RNTI per UE and hands both to the extraction.

Reason. Under the logical handover model adopted in Phase 3 the physical data link never moves, so the anchor's scheduler is the only place these observables exist; in a real network they would follow the serving cell. This is a documented simplification consistent with the logical handover deviation, and the affected columns remain internally consistent because every UE is treated identically.

**20 July 2026. Phase 4 schema appended to the locked Phase 3 schema.**

Decision. phase4FeatureSchema returns the Phase 3 column list obtained by calling phase3FeatureSchema (never by copying names) with twelve columns strictly appended: cqi_mean, cqi_var, cqi_trend_perS, mcsDL_mean, mcsDL_var, mcsUL_mean, mcsUL_var, ulVol_bytes, dlVol_bytes, dlulAsym, trafficBurstiness_cv, thr_mean_bps. writeFeatureCSV now asserts the Phase 4 schema; value formatting, file naming and newline handling are unchanged.

Reason. The Phase 3 schema was locked as the set all later phases append to; appending preserves that contract, since a Phase 3 CSV is an exact column prefix of a Phase 4 CSV and a Phase 4 file with the new columns truncated is byte-identical to its Phase 3 counterpart. From Phase 4 onward the expanded list is the locked schema.

**20 July 2026. Traffic features computed from MAC byte counters, sampled mid-run.**

Decision. The windowed traffic features difference the cumulative MAC.TransmittedBytes and MAC.ReceivedBytes counters of each UE, sampled every 0.1 s by the trafficSampler class and step-interpolated at the window edges; the App-layer counters are logged alongside for diagnostics only. Burstiness is the coefficient of variation of the per-interval total byte increments inside the window.

Reason. The MAC counters meter what actually crosses the radio interface, which is what a network operator observes; the App counters describe what the UE generated. End-of-run totals cannot provide burstiness at all, as the Phase 1 script already demonstrated with constant and bursty sources that match at run level, so a mid-run sample series is required. The 0.1 s period gives one hundred increments per 10 s window at negligible cost, and the step interpolation keeps the deltas deterministic.

**20 July 2026. RMa scenario timing aligned with UMa.**

Decision. phase4_RMa.m runs 30.5 s with the 10 s window, 1 s stride and 0.5 s settle time, identical to phase4_UMa.m. The copied phase3_RMa.m retains its 5 s run with a 2 s window.

Reason. The Phase 3 RMa values were smoke-test settings, and window lengths are part of the feature definition: rows computed from 2 s windows are not comparable with rows from 10 s windows, so the UMa and RMa CSVs could not have been concatenated. Aligning the timing makes the two forks emit rows under one definition.
