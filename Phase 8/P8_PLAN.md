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
  models/                    frozen pipelines and the code that reads them (see setup below)
  p8_config.m                all tunables, paths, and the integrity assertions
  p8_util.m                  cluster bootstrap, paired tests, metric wrappers, plot style
  p8_score.m                 scores every condition with every model, once
  p8_holdout.m               honest hold-out performance                        D8.1
  p8_evasion_individual.m    each evasion action against the honest baseline    D8.2
  p8_evasion_combined.m      the combined condition, and whether actions compound  D8.3
  p8_fpr_audit.m             did the operating point hold under every condition  D8.4
  p8_base_rate.m             predictive value and alert load against prevalence  D8.5
  p8_frontier.m              detectability against mission cost                 D8.6
  results/  figures/
```

Scripts are named for what they do; the deliverable each satisfies is recorded in its
header comment and in the table below. Outputs follow the same convention.

`p8_score.m` is the only script that reads a raw feature CSV or opens a frozen model,
so it is the only one that needs rerunning when the dataset changes. The one exception
is the terrestrial-invariance diagnostic in `p8_fpr_audit.m`, which asks a question
about the features themselves and so has to reopen them.

### Manual setup

Once, after `freeze_models.m` has completed in Phase 6. Everything is a copy, because a
frozen pipeline evaluated through a live working directory is not really frozen, and
because the `.mat` files carry function handles into `phase6_models.m` that will not
resolve unless that file is on the path.

1. Create three folders inside `Phase 8/`: `models`, `results`, `figures`.
2. Copy from `Phase 6/models/` into `Phase 8/models/`:
   - every `frozen_*.mat` (five of them)
3. Copy from `Phase 6/results/` into `Phase 8/models/`:
   - `freeze_manifest.csv`
4. Copy from `Phase 6/` into `Phase 8/models/`:
   - `phase6_util.m`
   - `phase6_models.m`
   - `score_pipeline.m`
5. Open `p8_config.m` and confirm `C.missionCostFile` points at the per-seed mission
   cost table you intend to use. It is named explicitly rather than found by pattern
   because more than one timestamped run sits in `Phase 7/results/`.

`p8_config.m` adds `Phase 8/models` to the path, so nothing else needs configuring. If
any of the above is missing, the first script run will say which.

### Run order

Set the current folder to `Phase 8` and run these one at a time. `p8_score` prints the
list again when it finishes.

| Order | Script | Deliverable | Depends on | Writes |
|---|---|---|---|---|
| 1 | `p8_score` | prerequisite | the frozen models | `scores_window.csv`, `scores_ue.csv`, `thresholds_frozen.csv`, `provenance.csv` |
| 2 | `p8_holdout` | D8.1 | `p8_score` | `holdout.csv`, `holdout_by_scenario.csv`, `holdout_roc.png` |
| 3 | `p8_evasion_individual` | D8.2 | `p8_score` | `evasion_individual_summary.csv`, `evasion_individual_perrun.csv`, `evasion_individual_perue.csv`, `evasion_individual_paired.png` |
| 4 | `p8_evasion_combined` | D8.3 | `p8_evasion_individual` | `evasion_combined_summary.csv`, `evasion_combined_perue.csv`, `evasion_combined_interaction.png` |
| 5 | `p8_fpr_audit` | D8.4 | `p8_score` | `fpr_audit.csv`, `fpr_audit_terrestrial_invariance.csv`, `fpr_audit.png` |
| 6 | `p8_base_rate` | D8.5 | `p8_holdout` | `base_rate_curve.csv`, `base_rate_summary.csv`, `base_rate.png` |
| 7 | `p8_frontier` | D8.6 | `p8_score` | `frontier.csv`, `frontier_perrun.csv`, `frontier_allmodels.csv`, `frontier.png` |
| 8 | `p8_latency` | D8.7 | `p8_score` | `latency_under_evasion.csv`, `F8_7_latency_under_evasion.png`, `T8_11_latency_under_evasion.png` |

Every stage now also writes report figures into `figures/` and appends its headline
numbers to `results/phase8_key_results.txt`. Tables worth quoting are drawn as figures
(`T8_*.png`) rather than printed to the console. `report_util.m` sits in `Phase 8/` and
is put on the path by `p8_config`; it does not need copying into `models/`.

Only `p8_score` is expensive. Stages 2 to 7 read its score tables, so any of them can be
rerun on its own while a table or figure is being settled.

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
- **D8.7 (detection latency under evasion) is now built**, as `p8_latency.m`, against the
  same score tables. It applies the frozen threshold at every observation length rather
  than re-deriving it as Phase 6 does, because re-deriving on the hold-out would be
  fitting an operating point to the test set; the achieved false positive rate is
  therefore plotted beside the recall rather than assumed away.

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
