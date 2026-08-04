# Monday 3 August 2026 — Phase 7 forked from the Phase 5 pipeline

**Logbook**

- The Phase 7 folder was created as a copy of the Phase 5 pipeline, carrying over the thirty one core functions a dataset run touches unchanged and renaming the five that carry a phase prefix, namely `phase5_Pipeline`, `phase5_ScenarioGen`, `phase5_Progress`, `phase5_ResolveRNTI` and `phase5_CostModel`. The channel stack, measurement layer, extraction layer and feature schema were left byte identical so Phase 7 rows stay comparable with the honest dataset.
- `DEPENDENCIES.md` was written to record what the fork depends on, and `phase7_SmokeTest` was added to verify an install reproduces a known good machine, checking environment and licences, then the closed form analytics, then a two run batch through the real runner on a two worker pool.

# Tuesday 4 August 2026 — Evasion branches sized and wired into the batch runner

**Logbook**

- The adversarial set was sized at 45 runs, three evasion branches across the fifteen Phase 5 hold-out seeds 46 to 60, giving 87 hours on twelve workers, 5.9 GB and roughly 38 aerial trajectories per branch. Channel quality indicator falsification was excluded from simulation because it costs the drone no altitude, no payload and no time and therefore cannot sit on a detectability against mission cost frontier, and reduced speed was folded into the combined branch rather than run alone, since speeds are drawn inside the toolbox mobility model and diverge the trajectory from the first timestep.
- `simulationTime` was cut from 60.5 s to 40.5 s while `windowLen`, `windowStride` and `settleTime` were held at the Phase 5 values, so each row remains the same feature vector and the frozen classifier scores the output unchanged, at 30 rows and 3 independent windows per UE-run against 50 and 5. The honest comparator is to be recomputed from the first 30 windows of each hold-out UE-run, which costs no simulation. Durations below 40.5 s were rejected because two independent windows per trajectory is too few and shorter runs thin the handover events the descent branches act through.
- `phase7_RunBatch` was reworked to enumerate one run per condition and seed pair rather than one per seed, with the scenario keyed to the seed as `scenarioCycle(mod(seed-1, nCycle)+1)`; the inherited Phase 5 form indexed on position in the batch and would have silently reassigned scenarios once the run index stopped tracking the seed, breaking every seed match. Aerial altitude ranges are set degenerate rather than removed so the generator still draws one value per aerial UE and the scenario stream stays aligned with the honest twin, and the overlay asserts that it has not altered `cfg.population`, whose failure mode is otherwise silent.
