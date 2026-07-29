# Removed 28 July 2026: checkpointing

These files implemented resumable runs and were removed from the code path
when the overnight shutdown that motivated them was fixed at the machine.
They are kept here, off the MATLAB path, as the record behind the deviations
log entry of 28 July; nothing in Phase 5 references them.

- `phase5_Checkpoint.m` — per-run marker I/O and run classification.
- `phase5_RepairCheckpoints.m` — audit and repair of checkpoint state.
- `checkpoints_stale/` — the markers left by the six-seed batch, now meaningless:
  a run's feature CSV is written once, after `run()` returns, so its presence
  is the completion record.

To reinstate: `run()` takes a DURATION and cannot be called twice before
R2026a, so do not segment the simulation. Use a periodic `scheduleAction`
that re-extracts the features and rewrites the CSV, and write no CSV before
`settleTime + windowLen` or the extractor emits a clipped window.
