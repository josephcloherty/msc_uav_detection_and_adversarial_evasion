# Phase 5 dataset sizing

Source of truth: Phase 5 code as committed, plus the twelve completed runs in
`data/` (`manifest_20260731_112643.csv`, `costmodel_measured.csv`). Nothing below
is carried over from Phase 2 or Phase 3.

---

## 1. Findings

Only items that move a number or require a code change.

| # | Finding | File |
|---|---------|------|
| F1 | **Traffic profiles are class-differentiated, not identical.** Aerial UL 4000 kbps / DL 100 kbps continuous; terrestrial DL 2000 kbps / UL 200 kbps on-off. Measured on the 6,350 completed rows, `ulVol_bytes`, `ulThr_bps`, `trafficIdle_frac` and `dlulAsym` each give **AUC = 1.0000** — perfect separation. The label is readable from traffic alone and the propagation claim becomes untestable. | `phase5_Config.m` L243-246 |
| F2 | **Speed ranges are disjoint.** Aerial [15 30] m/s, terrestrial [1 5] m/s, no overlap. `servSINR_autocorr1` 0.633, `servSINR_fadeRate` 0.632, `hoRate_perS` 0.575 AUC are all speed-driven. There is no vehicular terrestrial class. | `phase5_Config.m` L224-225 |
| F3 | **Handover features are near-degenerate in UMa and RMa, and inverted.** Mean handovers per 10 s window: UMa aerial 0.400 vs terrestrial 0.492; RMa 0.291 vs 0.542; UMi 2.873 vs 1.158. Zero-handover windows 71% / 80% / 21% for aerial. `meanInterHO_s` is 77.8% NaN. In two of three scenarios the terrestrial class hands over *more*. | measured, `data/features_*.csv` |
| F4 | **Five schema columns are entirely NaN across all twelve runs**: `cqiSubbandSpread_mean`, `ta_mean`, `ta_var`, `ta_trend_perS`, `ta_range`. The R2024b `UEContext` probes find nothing. The smoke check misses this because check 11 is an OR against `ri_mean`. 70 of 75 numeric features are live. | `cqiLoggingScheduler.m` L232-267; `phase5_SmokeCheck.m` L119-120 |
| F5 | **Cost constant is 17% above the configured prior.** Measured k = 39.34 s per (sim-s x gNB x UE) at 12 workers, n = 12, spread 38.74-40.16 (3.6%). Config prior is 33.6. Every runtime figure below uses 39.34. | `costmodel_measured.csv`; `phase5_Config.m` L120 |
| F6 | **`configureULforSRS` hardcodes `servingIdx = 1` while the pipeline anchors each UE to its nearest gNB.** The two disagree whenever the anchor is not gNB 1, which is the normal case. Empirically inert (UEs anchored to gNB 2-5 still reach five visible cells, and all twelve runs completed), but the invariant is unasserted and would fail silently. | `configureULforSRS.m` L37; `phase5_Pipeline.m` L92-105 |

Checks that came back clean and change nothing:

- **SRS ceiling.** Correctly asserted on *total* UE count, not per-cell, because every UE holds an SRS link to every gNB. Max population is 8 + 6 = **14 of 16**. Does not bind. Headroom is 2. `phase5_ScenarioGen.m` L76-85.
- **Initial attachment.** Not hardcoded. Each UE connects to its nearest gNB, which becomes the anchor for the run. Manifest `anchorLoadMax` 3-6 across 9-14 UEs confirms the spread. **No startup handover cascade.** `phase5_Pipeline.m` L92-105.
- **Altitude.** All three scenarios clear their TR 36.777 floor, and the generator asserts it: UMa 40-200 m vs 22.5 m, RMa 40-200 m vs 10 m, UMi 40-150 m vs 22.5 m. Channel dispatch keys on **live UE z per packet**, not declared type. `phase5_ScenarioGen.m` L94-99; `tr36777ChannelModel.m` L155.
- **CQI to MCS.** `cqiLoggingScheduler` delegates every decision to `nrScheduler` and only logs, so a falsified CQI *would* propagate to granted DL MCS through stock link adaptation. But there is **no injection point** — the subclass reads `UEContext` and never writes it. Phase 7 needs one. `cqiLoggingScheduler.m` L1-10, L134-140, L206-236.
- **Leakage.** `scenario` and `seed` are columns 1-2 and `ueID` is column 3, so (scenario, seed) is a usable run key and grouped splitting works. No dedicated `runID`. `phase5FeatureSchema.m`.

---

## 2. Parameters

Only values that drive sizing.

| Parameter | Value | Source |
|---|---|---|
| `simulationTime` | 60.5 s | `phase5_Config.m` L324 |
| `windowLen` | 10 s | L325 |
| `windowStride` | 1 s | L326 |
| `settleTime` | 0.5 s | L327 |
| `scanPeriod` | 0.01 s | `handoverManager.m` L11 |
| `scanStartTime` | 0.0795 s | `handoverManager.m` L12 |
| `numGNB` (all three scenarios) | 5 | `phase5_Config.m` L390, L409, L424 |
| `numTerrestrialUE` | 8 | L197 |
| `pMultiAerial` | 0.5 | L203 |
| `singleAerialCount` | 1 | L206 |
| `aerialSwarmSizeRange` | [2 6] | L212 |
| `srs.maxUEsPerGNB` | 16 (on total UEs) | L369 |
| `seedRange` | 13:36 (24 runs) | L67 |
| `scenarioCycle` | [UMa RMa UMi] | L77 |
| `numWorkers` | 12 | L85 |
| Feature columns | 76 (1 string + 75 numeric) | `phase5FeatureSchema.m` |
| k, wall s per (sim-s x gNB x UE) | **39.34** measured @ 12 workers | `costmodel_measured.csv` |
| `replay.save` | true, `-v7.3` | L353-354 |
| Traffic sampler period | 0.1 s | `trafficSampler.m` L30 |
| Position recorder rate | 100 Hz | `positionRecorder.m` L17 |

Not determined by the code:

- Number of runs actually needed. `seedRange` is a free choice.
- Development / hold-out split. No splitting logic exists anywhere in Phase 5.
- Duration scaling of k. Calibrated at exactly one duration (60.5 s) at the production pool size. See §4.
- Wall-clock budget and machine availability.

---

## 3. Rows

### Per UE-run

```
raw scans        = floor((60.5 - 0.0795) / 0.01) + 1            = 6043
first kept scan  = 0.0795 + 0.01 * ceil((0.5 - 0.0795)/0.01)    = 0.5095 s   (k = 43)
last scan        = 0.0795 + 0.01 * 6042                         = 60.4995 s
raw kept         = 6043 - 43                                    = 6000
windowed rows    = floor((60.4995 - 10 - 0.5095) / 1) + 1       = 50
independent      = floor((60.4995 - 0.5095) / 10)               = 5
```

Manifest confirms exactly 50: `numRows` = 450 at 9 UE, 500 at 10, 650 at 13, 700 at 14.

| Quantity | Per UE-run |
|---|---|
| Raw feature-log scans | 6,043 |
| Raw scans retained after settle | 6,000 |
| Windowed rows before warm-up discard | 50 |
| Windowed rows after warm-up discard | **50 (no second discard exists)** |
| Independent, non-overlapping windows | 5 |
| Window overlap | 90% |

The 0.5 s settle is applied to the scan log *before* windowing (`extractWindowedFeatures.m` L120) and the window grid is anchored at the first retained scan. There is no post-windowing warm-up rule, so nominal and effective row counts per UE-run are the same 50.

### Per run

```
E[numAerial] = 0.5*1 + 0.5*mean(2..6) = 0.5 + 2.0 = 2.5      (measured 12-run mean 2.583)
E[numUE]     = 8 + 2.5 = 10.5                                (measured 10.583)
E[rows/run]  = 10.5 * 50 = 525
E[aerial share] = 2.5/10.5 = 23.81%                          (measured row share 24.41%)
```

### Batch totals, 60 runs

```
UE-runs            = 60 * 10.5   = 630        (aerial 150, terrestrial 480)
rows               = 630 * 50    = 31,500
aerial rows        = 150 * 50    = 7,500      (23.8%)
terrestrial rows   = 480 * 50    = 24,000
independent windows= 630 * 5     = 3,150      (aerial 750)
```

| Effective sample size | 60 runs |
|---|---|
| Nominal rows | 31,500 |
| Independent windows | 3,150 (aerial 750) |
| Distinct scenario realisations | 60 |
| Distinct UE trajectories | 630 (aerial 150) |

The nominal count overstates information by **10x**. The binding number is **150 aerial trajectories** against 70 live features.

### Storage

Least-squares fit over the twelve replay bundles:

```
replay MB = -56.3 + 23.85 * numUE      (9 UE -> 158, 10.5 -> 194, 14 -> 278)
```

| Item | Volume |
|---|---|
| Replay `.mat` per run at E[10.5] UE | 194 MB |
| Replay, 60 runs | **11.6 GB** |
| Feature CSV per run | 289 kB |
| Feature CSV, 60 runs | 17.3 MB |
| Existing 12 runs on disk | 2.35 GB |
| Phase 7, 54 runs at 13 UE | 13.7 GB |
| **Grand total** | **27.7 GB** |

---

## 4. Runtime

### Cost per run

```
wall_s = k * simulationTime * numGNB * numUE          k = 39.34 @ 12 workers
```

| numUE | Wall per run |
|---|---|
| 9 | 107,107 s = 29.8 h |
| 10.5 (expected) | 124,958 s = **34.7 h** |
| 13 | 154,758 s = 43.0 h |
| 14 | 166,610 s = 46.3 h |

Throughput at 12 workers = 12 / 34.7 = **0.346 runs/h = 8.3 runs/day**.

### What the estimator accounts for

Linear in simulated seconds, gNB count and UE count; k stored per pool size and taken as a median so one thermally-throttled run cannot drag later estimates (`phase5_CostModel.m` L159-189). Across 12 runs spanning 9-14 UEs and all three scenarios, k varies only 3.6%, so the numUE and scenario terms are sound.

### What it does not account for

- **No intercept.** The model passes through the origin, so all fixed per-run overhead is absorbed into k and mis-scales at other durations.
- **Duration scaling is calibrated at one point.** Every measurement is at 60.5 s. The only other calibration, the 21 July smoke runs, gives k = 14.9 (6 s, 7 gNB, 3 UE, serial) — a factor of **2.64** below the production figure. Whether that gap is fixed overhead, duration nonlinearity or pool contention is currently undetermined, and the three have opposite implications for longer runs.
- **Pool contention only as a bucket.** k = 33.6 at 6 workers, 39.34 at 12. Doubling workers costs 17% per run and still nets +71% throughput, but nothing extrapolates this to 16 or 24.
- **Handover and aerial load.** UMi seed 12 logged 217 handovers against UMa seed 10's 20, at k within 1.6%. Fine at these counts, unverified beyond them.
- **Makespan.** `predictWall` returns per-run wall; `phase5_DryRun` divides total CPU by worker count and so reports the *ideal* makespan, ignoring tail imbalance when runs exceed workers.
- **Pool startup, retries and replay write time.**

### Sensitivity, 60-run honest batch makespan (hours)

| k \ simulationTime | 45 s | 60.5 s | 90 s | 120 s |
|---|---|---|---|---|
| 35.00 | 114.8 | 154.4 | 229.7 | 306.2 |
| **39.34** | 129.1 | **173.6** | 258.2 | 344.2 |
| 45.00 | 147.7 | 198.5 | 295.3 | 393.8 |
| 50.00 | 164.1 | 220.6 | 328.1 | 437.5 |

The T columns assume the linear duration term holds. It has not been tested.

### Cheapest measurement that pins the duration term

One full-pool wave of 12 runs at `simulationTime = 6`, production population and scenarios, 12 workers. Predicted cost 12 x (39.34 x 6 x 5 x 10.5) / 3600 / 12 = **3.4 h**. Fit `wall = a + b*T` through that point and the existing 60.5 s measurements; extrapolate to 60.5 h and compare against the measured 34.7 h. A large `a` means the model over-charges long runs and longer durations are cheaper than the table implies.

### Total wall clock

| Batch | Runs | CPU | Makespan @ 12 workers |
|---|---|---|---|
| Honest | 60 | 2,083 h | **173.6 h = 7.2 d** |
| Phase 7 adversarial | 54 | 2,321 h | **193.4 h = 8.1 d** |
| Total | 114 | 4,404 h | 366.9 h = 15.3 d |

Budget check, 31 July 18:00 to 9 August 18:00 = 216 h:

| Contingency | Runs affordable |
|---|---|
| 0% | 74.7 |
| 10% | 67.2 |
| 15% | 63.5 |
| **20%** | **59.7** |

60 runs at 20% contingency. Launching 1 August 18:00 after the fixes lands at **8 August 23:30**, 18 h inside the deadline. Because `scenarioCycle` has length 3 and `skipExisting` is true, the batch is resumable and any prefix truncated at a multiple of 3 stays scenario-balanced.

### Contingency levers, in preference order

1. **Truncate the seed range at a multiple of 3.** Costs trajectories only, keeps balance, needs no code change.
2. **Raise `numWorkers` if cores allow.** Measure k at the new pool size with one wave first; contention rose 17% for the last doubling.
3. **Cut `numTerrestrialUE` 8 to 6.** Minus 19% per run, aerial trajectory yield unchanged, class balance improves to 29% aerial.
4. **Drop UMi from `scenarioCycle`.** Minus 33% of runs. UMi is the optional stretch fork, but it is also the only scenario where handover features are non-degenerate (F3).
5. **Cut `simulationTime` 60.5 to 45.5 s.** Minus 25%, costs one of five independent windows per UE-run and breaks comparability with everything already run. Last resort.

Do **not** cut `numGNB`. `numAboveThr_mean` is the strongest live feature at AUC 0.807 and it is a direct function of cell count.

---

## 5. Recommended configuration

| Setting | Recommended | Currently | Why |
|---|---|---|---|
| Runs (`seedRange`) | **13:72, 60 runs** | 13:36, 24 runs | 24 runs uses 69 h of a 216 h budget and yields only 60 aerial trajectories. 60 runs fits at 20% contingency. |
| `simulationTime` | 60.5 s, unchanged | 60.5 s | Trajectory diversity binds, not window count. More short runs beat fewer long ones per CPU-hour. |
| `numGNB` | 5, unchanged | 5 | |
| `numTerrestrialUE` | 8, unchanged | 8 | SRS headroom is only 2. |
| Aerial fraction | 23.8% expected, unchanged | 23.8% | Already straddles the D5.1 ~20% target. |
| Sparse / swarm split | **50 / 50, unchanged** | 50 / 50 | All-swarm would cut cost per aerial trajectory from 13.9 h to 9.9 h, but single-aerial runs are the operationally realistic detection case and are needed for the FPR operating point. |
| UMa / RMa / UMi | **20 / 20 / 20** | equal cycle | Unchanged; 60 is a multiple of 3. |
| Traffic | **identical profile both classes** | class-differentiated | F1. Non-negotiable. |
| Terrestrial speed | **pedestrian [1 5] / vehicular [8 30], 50-50** | [1 5] only | F2. Overlaps the aerial [15 30] range so speed no longer separates. |
| Dev / hold-out | **45 / 15 runs, split at run level** | none exists | Stratify by scenario and by single/multi aerial. Group on (scenario, seed). |

Disposition of the twelve completed runs: they carry both the traffic leak (F1) and the pedestrian-only terrestrial population (F2), so they cannot join the main dataset. Keep them as a labelled **traffic-differentiated ablation stratum** — they make the point that with realistic per-class traffic the problem is trivial, which motivates the neutralised design. No compute is wasted.

### Where the proposed shape was wrong

| Proposed | Corrected | Why |
|---|---|---|
| 51 windowed rows per UE-run | **50** | The grid is anchored at the first *retained* scan (0.5095 s) and the last scan is 60.4995 s, so starts run 0.5095 to 49.5095. |
| 41 rows after a 10 s warm-up discard | **50, no such discard** | Phase 5 discards on `settleTime` = 0.5 s before windowing only. No post-windowing warm-up rule exists. |
| 7 gNBs | **5** | All three scenarios set `numGNB = 5`. |
| 12 UEs per run | **10.5 expected**, 9 to 14 | 8 terrestrial fixed plus 1 or 2-6 aerial. |
| 720 UE-runs from 60 runs | **630** | 60 x 10.5. |
| 29,520 rows at 20.8% aerial | **31,500 at 23.8%** | 630 x 50. |
| 6,043 raw rows per UE-run | **6,043, confirmed** | Matches exactly at `scanStartTime` 0.0795 and `scanPeriod` 0.01. |
| 5 independent windows | **5, confirmed** | |
| 150 aerial UE-runs from 60 runs | **150, confirmed** | Coincidental: 60 x E[2.5]. |
| 33 adversarial runs, 198 aerial UE-runs | **54 runs, 270 aerial UE-runs** | 198 implies 6 aerial per run in every run; seed-matched hold-out runs average 5. |

---

## 6. Phase 7 adversarial set

Seed-matched re-runs of hold-out scenarios only. Same scenario, same seed, same UE
count and placement; the aerial UEs' behaviour is the only thing that changes, so
the terrestrial rows in each run are an unperturbed within-run control.

**Altitude sweep, primary swept parameter.** Six levels, chosen to bracket the
TR 36.777 UMa/UMi overlay floor at 22.5 m so the frontier crosses the channel-model
boundary rather than sitting on one side of it:

```
15, 22, 30, 45, 70, 100 m AGL
```

15 m and 22 m fall below the UMa and UMi `zBoundary`, so those UEs take the
terrestrial TR 38.901 branch — the maximum-evasion, maximum-mission-cost end of
the frontier. Six levels is the minimum that resolves a knee; the current honest
runs draw altitude uniformly over [40 200], so the sweep also extends below
anything in the training set.

**Design.** Six seed-matched hold-out runs per condition, selected from the 15
hold-out runs to be multi-aerial (5 aerial UEs each).

| Condition | Runs | Aerial trajectories | Aerial rows | Independent aerial windows | Terrestrial control rows |
|---|---|---|---|---|---|
| Altitude 15 m | 6 | 30 | 1,500 | 150 | 2,400 |
| Altitude 22 m | 6 | 30 | 1,500 | 150 | 2,400 |
| Altitude 30 m | 6 | 30 | 1,500 | 150 | 2,400 |
| Altitude 45 m | 6 | 30 | 1,500 | 150 | 2,400 |
| Altitude 70 m | 6 | 30 | 1,500 | 150 | 2,400 |
| Altitude 100 m | 6 | 30 | 1,500 | 150 | 2,400 |
| **Altitude subtotal** | **36** | **180** | **9,000** | **900** | **14,400** |
| Traffic reshaping | 6 | 30 | 1,500 | 150 | 2,400 |
| Handover suppression | 6 | 30 | 1,500 | 150 | 2,400 |
| Combined | 6 | 30 | 1,500 | 150 | 2,400 |
| **Total** | **54** | **270** | **13,500** | **1,350** | **21,600** |

```
wall per run @ 13 UE = 39.34 * 60.5 * 5 * 13 = 154,758 s = 43.0 h
CPU      = 54 * 43.0                          = 2,321 h
makespan = 2,321 / 12                         = 193.4 h = 8.1 d
storage  = 54 * (-56.3 + 23.85*13)            = 13.7 GB
```

30 independent aerial trajectories per frontier point supports a mean detection
rate with a usable confidence interval. Do not quote the 1,500 aerial rows per
point as the sample size.

If Phase 7 does not fit, the cheapest lever is an **altitude-stratified swarm**:
assign each of the 5-6 aerial UEs in a run a different altitude level, so one run
yields most of the sweep. That gives 6x the levels per CPU-hour but breaks strict
seed-matching against the honest run, since the aerial population's altitude
distribution changes. Use it only after truncating conditions.

---

## 7. Action list

Before the batch is committed, in priority order.

| # | Action | File | Blocking |
|---|---|---|---|
| 1 | Set both classes to one identical traffic profile. Keep `rateJitterFrac` and `timingJitterFrac` for within-class variation. Re-check that `dlulAsym` and `trafficIdle_frac` AUC fall to chance on the smoke output. | `phase5_Config.m` L243-246 | **Yes.** Without this the dataset answers no research question. |
| 2 | Add a vehicular terrestrial speed class [8 30] m/s at 50% of terrestrial UEs, drawn per UE from the scenario stream. Record the sub-class in the manifest. | `phase5_Config.m` L224-225, `phase5_ScenarioGen.m` L108-122 | **Yes.** Otherwise altitude and speed are inseparable. |
| 3 | Update `cfg.batch.costModel.sPerSimSecPerGNBPerUE` from 33.6 to 39.34, or delete the line and rely on the measured store. | `phase5_Config.m` L120 | No, but every dry run under-predicts by 17% until done. |
| 4 | Set `seedRange = 13:72`. | `phase5_Config.m` L67 | Yes, sizing. |
| 5 | Bind `configureULforSRS` to the caller's actual anchor index instead of the hardcoded `servingIdx = 1`, and assert every UE ends with exactly `numGNB` links. | `configureULforSRS.m` L37, `phase5_Pipeline.m` L84-105 | No. Inert today, silent if it ever bites. |
| 6 | Run the 6 s calibration wave (§4) before launching, 3.4 h, to bound the duration term. | new | No. Cheap insurance on a 174 h commitment. |
| 7 | Either fix the TA and subband-CQI probes against the R2024b `UEContext`, or drop the five dead columns from the schema. Do not ship them as NaN. | `cqiLoggingScheduler.m` L232-267 | No, but do it before Phase 6 feature importance. |
| 8 | Change smoke check 11 from OR to AND, and add a check that no column is entirely NaN. | `phase5_SmokeCheck.m` L119-120 | No. This is why F4 survived to a full batch. |
| 9 | Add a `runID` column, or document (scenario, seed) as the grouping key for `GroupKFold`. | `phase5FeatureSchema.m` | No. Grouping is already possible. |
| 10 | Add a CQI write hook to `cqiLoggingScheduler` so a falsified UE-reported CQI can be injected before the base-class call. | `cqiLoggingScheduler.m` L134-140 | Phase 7 only, not Phase 5. |

Actions 1 and 2 invalidate the twelve completed runs for the main dataset. That is
the correct trade: 48 h of compute against a dataset that cannot support its own
conclusion.

---

## 8. Logbook

# Friday 31 July 2026 — First full batch closed and the dataset sized against it

**Logbook**

- The twelve seed batch completed with all runs marked ok, giving 6,350 rows over 127 UE-runs and a measured cost constant of 39.34 wall seconds per simulated second per gNB per UE at twelve workers, seventeen per cent above the 33.6 prior held in `phase5_Config`. Row geometry was confirmed exactly against the manifest at 6,043 raw scans, 50 windowed rows and 5 independent windows per UE-run.
- Per feature separation was measured on the completed rows before sizing the main batch, and four traffic columns returned an area under the curve of exactly 1.0000. The class traffic profiles carried in `cfg.traffic` make the label directly readable, so the batch was held and the profiles are to be made identical across classes before relaunch.
- Aerial and terrestrial speed ranges were found to be disjoint at [15 30] and [1 5] m/s, and handover counts per window came out near degenerate and inverted in UMa and RMa at 0.400 against 0.492 and 0.291 against 0.542. A vehicular terrestrial class at [8 30] m/s was specified to break the speed confound, and the honest batch was sized at 60 runs, 174 hours at twelve workers, for 630 UE-runs and 150 aerial trajectories.

---

## 9. Deviations log

**31 July 2026 — Serving index in configureULforSRS bound to the pipeline's anchor cell.**

**Decision.** The reconstructed helper `configureULforSRS` held a hardcoded `servingIdx = 1` and skipped `gNBs(1)` when establishing the dedicated uplink links, on the assumption inherited from the Fudan repository scripts that the first cell in the array is the serving cell. `phase5_Pipeline` instead connects each UE to its nearest gNB, so the two disagree for every UE whose anchor is not the centre site, which is the majority under the ring layout. The helper now takes the anchor index from the caller and skips that cell, and the pipeline asserts that each UE finishes with exactly `numGNB` links before the simulation starts.

**Reason.** The measurement layer depends on every gNB receiving SRS from every UE, and the handover managers read per cell uplink SINR from those reception events alone. A mismatch between the skipped cell and the separately connected serving cell would either leave one cell unable to measure a UE, silently emptying a column of the SINR snapshot and biasing every cell geometry feature downward, or attempt a duplicate connection. Inspection of the twelve completed runs found neither symptom, since UEs anchored to cells two through five still reached five visible cells, so the defect is latent rather than active on the installed release. It is nonetheless an unasserted invariant sitting underneath the primary feature block, and its failure mode is silent, so it was corrected and made checkable rather than left to depend on undocumented toolbox behaviour.

**31 July 2026 — Write access to the scheduler CQI context added for the Phase 7 falsification path.**

**Decision.** `cqiLoggingScheduler` delegates every scheduling decision to `nrScheduler` and reads `UEContext` for logging only, so there is no point at which a UE reported channel quality indicator can be altered before link adaptation consumes it. A guarded write hook is to be added to the subclass, applied to the downlink CQI and rank entries of `UEContext` immediately before the base class call and active only when an evasion policy is configured, leaving the honest path byte identical.

**Reason.** Research question three requires the adversarial UE to falsify its reported channel quality and requires the consequence to be observable in the granted modulation and coding scheme, which is the correct framing because the scheme is selected by the gNB from the reported indicator rather than declared by the UE. The uplink estimate is derived by the gNB from SRS and stays honest, so the pair separates spoofable from non spoofable quality reporting, which is the distinction the threat model rests on. Intervening in the scheduler subclass rather than in the toolbox CSI reporting path keeps the adaptation inside project owned code and leaves the installed support package unmodified.
