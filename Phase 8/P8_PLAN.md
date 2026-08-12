# Phase 8 — review of the plan and script architecture

Written 12 August 2026. Reviewed against the artefacts actually present in
`Phase 6/` and `Phase 7/` on that date.

---

## Part 1 — What the data says about the plan

### Inventory as inspected

| Item | State |
|---|---|
| `Phase 6/models/` | **empty**. `freeze_models.m` has not been run. |
| Dev seeds | 1 to 45, 45 CSVs in `Phase 6/data/`. |
| Hold-out seeds | 46 to 60, 15 runs. Seed boundary is clean, no overlap. |
| Feature schema | 76 columns, identical names and identical order in Phase 6 and Phase 7 CSVs. |
| Honest hold-out | 7,250 rows, 145 UE-runs, **50 windows per UE-run**, 120 terrestrial + 25 aerial. |
| Evasive conditions | `lowAltitude`, `trafficReshaping`, `combined`. Each 4,350 rows, 145 UE-runs, **30 windows per UE-run**, 120 terrestrial + 25 aerial. |
| Mission cost | `phase7_missioncost_perseed_*.csv`, 135 rows = 3 conditions x 3 profiles x 15 seeds. Composite cost `C_op`. Two timestamped result sets present. |
| Dev thresholds | Per-UE 1% nominal FPR is achieved at 0.833% (3 false positives out of 360 terrestrial UE-runs). |

### Issue 1 — Window-length mismatch invalidates D8.2 and D8.3 as written

Honest hold-out runs are 60 s and yield 50 windows per UE-run. All three evasive
conditions are 40 s and yield 30. The per-UE decision rule is a mean posterior over
the windows in a UE-run, so its sampling variance depends on the window count, and if
the aerial signature varies along the trajectory then 30 windows samples a different
part of the flight from 50.

A recall difference measured this way conflates "the evasion policy worked" with
"less of the flight was observed". That is fatal to the headline claim.

`phase7_MissionCost.m` already truncates to 30 windows on both sides
(`nWin_honest = nWin_evade = 30` in every per-seed row), so the precedent exists and
Phase 8 must match it or the cost and detectability axes of D8.6 will not refer to
the same observation interval.

**Fix.** Truncate every UE-run to the first `N_WIN` windows before any paired
comparison. `phase6_util/perUEScore` already accepts a `maxWin` argument, so this is
a one-line change at the call site. Set `N_WIN` in `p8_config.m` and assert that
every condition has at least that many windows per UE-run. If the final dataset
regenerates the evasive runs at 60 s the constant becomes 50 and the truncation is a
no-op, which is the right behaviour.

D8.1 should report the honest hold-out at both lengths: full 50 windows, which
matches the geometry the models were frozen on, and truncated to `N_WIN`, which is
the baseline every evasive comparison is drawn against. Quoting one number and using
the other is the trap here.

### Issue 2 — Per-UE statistics have almost no power, and the plan does not acknowledge it

There are **25 aerial UE-runs in the entire hold-out**, distributed across the 15
runs as: twelve runs with 1, then one run each with 3, 4 and 6. Three runs therefore
carry 13 of the 25 aerial UE-runs.

Consequences:

- Per-UE recall moves in steps of 4 percentage points. There is no such thing as a
  1-point recall change at this level.
- D8.1's run-level bootstrap resamples 15 runs of which three dominate the aerial
  mass. The interval will be wide and visibly lumpy, plausibly spanning 20 points or
  more. Better to know that now than in the viva.
- D8.2's "seed-paired recall difference" is close to degenerate. For twelve of the
  fifteen runs the per-seed recall is a single Bernoulli trial, so the paired
  difference lives in {-1, 0, +1}. A signed-rank test on that has essentially no
  resolution.
- The per-UE false-positive rate is quantised at 1/120 = 0.833%, so D8.4 can only
  confirm the 1% operating point to plus or minus 0.83%.

**Fix, analysis side.** Keep per-UE recall as the headline descriptive number with an
honest interval, but do the paired inference on the **continuous per-UE score**
rather than the binary decision. Per run, take the mean per-UE score of the aerial
UEs under honest and under the condition, pair them, and test the shift with a
Wilcoxon signed-rank plus a run-level bootstrap. That statistic uses all 25 aerial
UE-runs at full resolution instead of collapsing each to a bit. Report both, and be
explicit that the recall figure is descriptive and the score shift carries the
inferential claim.

**Fix, data side, if the final dataset is not yet frozen.** Allocate a fixed number
of aerial UEs per run, two would give 30 balanced aerial UE-runs, rather than letting
the aerial count vary from 1 to 6. Balanced pairing is worth more here than a few
extra aerial UEs. This is a Phase 5 or Phase 7 generation parameter, so it has to be
decided before the runs are made, not in Phase 8.

### Issue 3 — D8.3's additivity test is on the wrong scale

Recall is bounded in [0, 1], so "does the combined degradation equal the sum of the
individual degradations" is not a well-posed question near the floor or the ceiling:
two 60-point drops cannot sum. Test additivity on the logit of the per-UE score, or
equivalently on log detection odds, where superadditive and subadditive have a
meaning. Report the recall arithmetic alongside as description, and say plainly which
of the two is the claim.

Note also that only two individual conditions exist on disk. D7.1 specified three
evasion actions including handover suppression. If a third condition appears in the
final dataset, the scripts must pick it up without editing, so conditions should be
discovered from `data/evasive/*` rather than hardcoded.

### Issue 4 — D8.4 needs a stated mechanism, not just a number

Terrestrial rows are **not** identical between honest and evasive. On UMa seed 46,
147 of 240 comparable terrestrial rows differ in `cqi_mean` and 39 differ in
`servSINR_mean_dB`. That is good news, because it means the FPR audit is a real
measurement rather than a tautology, but it needs an explanation in the write-up.

Two candidates: physical coupling, where the aerial UE's altered altitude and traffic
change interference and scheduling for everyone in the cell, which is a legitimate
and interesting finding; or RNG-stream divergence, where changing the aerial policy
shifts the random stream and the terrestrial UEs are simply different draws, which
would weaken the seed-pairing that D8.2 rests on. Add a short diagnostic that checks
whether terrestrial trajectories are byte-identical across conditions. If they are,
the shift is physical. If they are not, say so and treat the pairing as
scenario-level rather than realisation-level.

### Issue 5 — D8.5 should be a curve, not a number

A single PPV figure at one assumed prevalence is fragile and invites the obvious
objection. Sweep prevalence over several orders of magnitude, roughly 1e-5 to 1e-2,
and plot PPV against it at the frozen operating point. Derive alerts per cell per day
from an explicitly stated UEs-per-cell-per-day assumption, shown on the figure rather
than buried in the text. The Axelsson argument is much stronger as a curve.

### Issue 6 — D8.6 has an undeclared choice and only four points

Mission cost exists for three profiles: `reconnaissance`, `remotePiloting`,
`terminalApproach`. The plan does not say which one anchors the headline figure. Pick
one as primary and put the other two in an appendix, or use a three-panel figure.
Either is defensible, but it must be a stated decision rather than whichever the
script happened to read first.

The frontier itself is four points per profile: honest anchored at cost zero, plus
three conditions. Plot the per-seed points faintly behind the condition means with
their intervals so it reads as a distribution rather than four dots, and mark the
Pareto-dominant subset.

Finally, `Phase 7/results/` currently holds two timestamped mission-cost result sets,
one with `nSeeds = 1` and one with `nSeeds = 15`. The script must take an explicit
file path from config, not glob for the latest.

### Missing deliverable — detection latency under evasion

The latency curve is recorded as a novel contribution absent from the prior art, and
`Phase 6/latency_curve.m` already produces it for the development set. Phase 8 has no
equivalent. Recall against windows observed, one curve per condition on shared axes,
answers "does evasion buy the drone time" as well as "does it buy the drone misses".
That is a strong and cheap result and it is the natural companion to D8.6.

**Recommend adding D8.7: hold-out detection latency, honest and per condition.**

### Two additions worth having

- **Per-scenario breakdown.** The hold-out is five seeds each of UMa, RMa and UMi.
  The plan pools them. A supporting table by scenario shows the result is not carried
  by one deployment type. Not a headline, but an examiner will ask.
- **Provenance block.** Freeze date, model file checksums, an assert that dev seeds
  and hold-out seeds are disjoint, and an assert that feature names and order match
  the frozen pipeline exactly. Cheap to write, and it is precisely what gets probed.

### Prerequisite

`Phase 6/models/` is empty. `freeze_models.m` must run and produce five
`frozen_*.mat` files plus `freeze_manifest.csv` before anything in Phase 8 executes.

---

## Part 2 — Script architecture

### One scoring script, not four

The suggestion was a separate test script for honest and for each condition. That is
worth resisting, for three reasons. Four near-duplicate scripts means four places for
a preprocessing or truncation bug to hide, and the whole point of the frozen pipeline
is that every condition is treated identically. D8.3, D8.4 and D8.6 all need every
condition in one table anyway, so the scripts would have to be joined downstream
regardless. And if a third evasion condition appears in the final dataset, a
condition-discovering loop needs no new code.

So: **one** script walks `data/honest` and `data/evasive/*`, applies all five frozen
pipelines, and writes long-format score tables. Everything after that reads those
tables and never touches a raw feature CSV again. That also means the expensive step
runs once.

### Layout, as built

```
Phase 8/
  models/                 frozen_*.mat, freeze_manifest.csv, phase6_util.m,
                          phase6_models.m, score_pipeline.m, COPIED.txt
  p8_setup.m              one-time: copy the frozen artefacts across, make folders
  p8_config.m             all tunables, paths, and the integrity assertions
  p8_util.m               cluster bootstrap, paired tests, scalar metric wrappers, plot style
  p8_score.m              scores every condition with every model, once
  p8_D1_holdout.m         D8.1
  p8_D2_conditions.m      D8.2
  p8_D3_compounding.m     D8.3
  p8_D4_fpr_audit.m       D8.4
  p8_D5_baserate.m        D8.5
  p8_D6_frontier.m        D8.6
  run_phase8.m            driver, runs the seven stages in order
  results/  figures/
```

One script per deliverable, plus a scoring stage that is not a deliverable but is the
prerequisite for all of them. `p8_score.m` is the only script that reads a raw feature
CSV or opens a frozen model; the deliverable stages read its two long-format score
tables. The one exception is the terrestrial-invariance diagnostic in D8.4, which asks
a question about the features themselves and so has to reopen them.

### Outputs

| Stage | Writes |
|---|---|
| `p8_score` | `scores_window.csv`, `scores_ue.csv`, `thresholds_frozen.csv`, `provenance.csv` |
| `p8_D1_holdout` | `D81_holdout.csv`, `D81_by_scenario.csv`, `D81_roc.png` |
| `p8_D2_conditions` | `D82_summary.csv`, `D82_perrun.csv`, `D82_perue.csv`, `D82_paired.png` |
| `p8_D3_compounding` | `D83_compounding.csv`, `D83_perue.csv`, `D83_interaction.png` |
| `p8_D4_fpr_audit` | `D84_fpr.csv`, `D84_terrestrial_invariance.csv`, `D84_fpr.png` |
| `p8_D5_baserate` | `D85_ppv.csv`, `D85_summary.csv`, `D85_ppv.png` |
| `p8_D6_frontier` | `D86_frontier.csv`, `D86_frontier_perrun.csv`, `D86_frontier_allmodels.csv`, `D86_frontier.png` |

### Decisions taken in the implementation

- **One scoring script, not one per condition.** Four near-identical scripts would be
  four places for a preprocessing or truncation mistake to hide, and the point of a
  frozen pipeline is that every condition is treated identically. Conditions are
  discovered from the folder tree, so a third evasion action needs no code change.
- **`N_WIN` defaults to the shortest UE-run observed across all conditions**, currently
  30. If the final dataset generates every condition at the same duration the
  truncation becomes a no-op, which is the correct behaviour.
- **The truncated honest baseline, not the nominal rate, is the reference.** Truncation
  widens the null distribution of the per-UE mean posterior and moves the achieved FPR
  off nominal. That belongs to observation length, not to any evasion policy.
- **Recall is descriptive, the log-odds shift is inferential.** Both are in every table.
- **Zero measured false positives are replaced by a rule-of-three upper bound** in D8.5,
  and the substitution is flagged in the output table. Taking a measured zero at face
  value would give PPV of one at every prevalence and delete the base-rate argument.
- **Three-panel frontier**, one panel per mission profile, so the core exhibit is not
  conditioned on a profile choice that would have to be defended.
- **The mission cost file is named explicitly** in `p8_config`, not found by pattern,
  because more than one timestamped run sits in `Phase 7/results`.
- **D8.7 (detection latency under evasion) was not built.** It remains the strongest
  cheap addition and can be written against the same score tables later.

### Execution order

```
>> freeze_models          % in Phase 6, produces models/frozen_*.mat
>> p8_setup               % once, copies them into Phase 8
>> run_phase8             % everything
```

Only `p8_score` is expensive and only it needs rerunning when the dataset changes. The
deliverable stages can be rerun individually while a table or figure is being settled.

---

## Summary of changes made to the plan

1. D8.1 reports the honest hold-out at both full and truncated window counts.
2. D8.2 pairs on the per-UE score as well as the binary decision. Recall change is the
   descriptive headline; the log-odds shift carries the inference.
3. D8.3 tests additivity on the log-odds scale, with the recall arithmetic reported
   beside it and flagged when the sum is not achievable on the bounded scale.
4. D8.4 adds the terrestrial-invariance diagnostic and prints every rate next to its
   own quantisation step.
5. D8.5 sweeps prevalence and reports a curve plus a break-even prevalence.
6. D8.6 is a three-panel figure with the mission cost file pinned in config.
7. Per-scenario breakdown and a provenance block are emitted as supporting output.
8. Still outstanding, and not something a script can decide: run `freeze_models.m`,
   and decide whether the final dataset can carry a balanced aerial allocation per run.
