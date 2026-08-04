# Phase 7 — MATLAB dependencies

Compiled by scanning every `.m` file in `Phase 7/` for calls that are not base
MATLAB, then checking each against the MathWorks documentation. Product
attribution below is as documented in August 2026; see the release note at the
end, because the system-level pieces changed product in R2026a.

---

## 1. Required to run a batch

These are exercised on the normal `phase7_RunBatch` path. Without any one of
them the batch cannot start.

| Product | Why it is needed | Called from |
|---|---|---|
| **MATLAB** | Base language, `table`/`string`, `RandStream`, file I/O | everywhere |
| **5G Toolbox** | The NR nodes, scheduler, channel and pathloss models | see 1.1 |
| **Wireless Network Toolbox**<br>(R2026a+)<br>*or* **Communications Toolbox** + the **Wireless Network Simulation Library** add-on (R2023a–R2025b) | The system-level simulator itself: event scheduling, node container, traffic models, mobility | see 1.2 |
| **Parallel Computing Toolbox** | `parfor` over runs, the pool, the progress `DataQueue` | see 1.3 |
| **Signal Processing Toolbox** | `db2mag`, one call on the per-packet pathloss path | see 1.4 |

### 1.1 5G Toolbox

| Function / class | Used in |
|---|---|
| `nrGNB` | `phase7_Pipeline` |
| `nrUE` | `phase7_Pipeline` |
| `nrScheduler` (subclassed) | `cqiLoggingScheduler` |
| `configureScheduler` | `phase7_Pipeline` |
| `connectUE` | `phase7_Pipeline`, `configureULforSRS` |
| `nrRLCBearerConfig` | `phase7_Pipeline`, `configureULforSRS` |
| `nrSRSConfig` | `phase7_Pipeline` (only when `cfg.srs.periodicitySlots` is set) |
| `nrCDLChannel` | `buildAerialCDL`, `buildUMiAVChannel`, `createScenarioChannels` |
| `nrPathLoss`, `nrPathLossConfig` | `tr36777ChannelModel` |
| `nrOFDMInfo` | `createScenarioChannels` |

`cqiLoggingScheduler` subclasses `nrScheduler`. Custom scheduler plug-in via
the `Scheduler` name-value argument was **introduced in R2024b**, so that is the
floor for this project regardless of anything else.

### 1.2 Wireless network simulation

| Function / class | Used in |
|---|---|
| `wirelessNetworkSimulator` (`.init`, `.getInstance`) | `phase7_Pipeline`, `cqiLoggingScheduler` |
| `addNodes` | `phase7_Pipeline` |
| `addChannelModel` | `phase7_Pipeline` |
| `run` (on the simulator) | `phase7_Pipeline` |
| `scheduleAction` | `phase7_Pipeline`, `handoverManager`, `rntiVerifier`, `positionRecorder`, `trafficSampler` |
| `networkTrafficOnOff` | `phase7_Pipeline` |
| `addTrafficSource` | `phase7_Pipeline`, `handoverManager` |
| `addMobility` | `phase7_Pipeline` |
| `statistics` (on a node) | `trafficSampler` |

### 1.3 Parallel Computing Toolbox

| Function | Used in |
|---|---|
| `parfor` | `phase7_RunBatch` |
| `parpool`, `parcluster`, `gcp` | `phase7_RunBatch` |
| `pctconfig` | `phase7_RunBatch` |
| `parallel.pool.DataQueue`, `afterEach`, `send` | `phase7_RunBatch`, `phase7_Pipeline`, `phase7_Progress` |

`phase7_RunBatch/assertParallelAvailable` already checks for this at startup
(`license('test','Distrib_Computing_Toolbox')` and `ver('parallel')`) and errors
rather than falling back to serial.

### 1.4 Signal Processing Toolbox

One call, `db2mag`, in `tr36777ChannelModel.m`:

```matlab
outputData.Data = outputData.Data.*db2mag(-pathLoss-sfDB);
```

This is the only thing pulling in Signal Processing Toolbox, and it is on the
per-packet hot path. If the licence is inconvenient, replace it with the
identity `db2mag(x) == 10.^(x/20)`:

```matlab
outputData.Data = outputData.Data.*10.^((-pathLoss-sfDB)/20);
```

That removes the dependency entirely with no change in result.

---

## 2. Needed only for the interactive replay

`replayScenario.m` builds a UI (`uifigure`, `uigridlayout`, `uiaxes`,
`uibutton`, `uislider`, `uilistbox`, `uialert`, `uigetfile`, `uiputfile`).

All of it is **base MATLAB App Building** — no extra toolbox. It also needs a
display, so it cannot run on a worker; the batch writes `.mat` replay bundles
instead and you open them afterwards with `replayScenario(path)`.

---

## 3. Present in the code but NOT required

| Thing | Status |
|---|---|
| **Python + `DDQN.py` / `DDPG.py`** | `handoverManager` calls `py.DDQN.*` and `py.DDPG.*` in its DQN and DDPG policies. Those policies are registered in the constructor but never invoked: `cfg.handover.useTr36777Mobility` is `true`, so `checkHandoverPolicy` calls `tr36777Mobility()` and returns. Dead code on this path. |
| **Reinforcement Learning Toolbox** | Not used. The agents are external Python, not `rlAgent` objects. |
| **Statistics and Machine Learning Toolbox** | Deliberately avoided. `sampleSpatialField` uses `erfc` instead of `normcdf`; `extractWindowedFeatures` has its own `iqr_` helper instead of `quantile`. |
| **Mapping Toolbox** | Deliberately avoided. `buildAerialCDL` and `buildUMiAVChannel` each define a local `wrapTo180`. |
| **`hArrayGeometry.m`** | MathWorks example helper (Copyright 2018–2022), vendored into `core/functions`. No extra product, but it is not your code. |

---

## 4. Release notes worth knowing

**R2024b is the floor.** Custom `nrScheduler` subclasses arrived in R2024b, and
`cqiLoggingScheduler` depends on that. The manifest records
`version('-release')` per run, so a mixed-release batch is detectable after the
fact.

**R2026a moved the goalposts.** In R2026a the system-level simulation moved out
of the Communications Toolbox Wireless Network Simulation Library add-on and
into a new licensed product, **Wireless Network Toolbox**. From R2026a,
`configureScheduler` and friends require a Wireless Network Toolbox licence *in
addition to* 5G Toolbox. On R2024b–R2025b the add-on route still applies.

Practically: if this runs today on R2024b, do not upgrade the machine to R2026a
mid-dataset without first confirming the licence covers Wireless Network
Toolbox. A part-finished batch is resumable, but only if MATLAB still starts.

**`run()` and checkpointing.** `run(networkSimulator, duration)` takes a
duration and cannot be called twice before R2026a, which is why the pipeline is
one call per run with no checkpointing.

---

## 5. Checking a new machine

Run `phase7_SmokeTest` on it. On the first machine — one you have already
confirmed good — it records `data/smoke_test/phase7_smoke_check.mat`; on every
machine after that it reruns the same checks and compares against that file,
so a missing product, a changed release or a drifted numeric result all fail
loudly. It covers everything in this document plus two tiny runs through
`phase7_RunBatch`, and takes a few minutes. `phase7_SmokeTest('quick', true)`
does the licence and analytic half in about a second without starting the
simulator.

The manual equivalent of the licence part:

```matlab
p = {'MATLAB','5G Toolbox','Wireless Network Toolbox','Communications Toolbox', ...
     'Parallel Computing Toolbox','Signal Processing Toolbox'};
v = ver; installed = {v.Name};
for k = 1:numel(p)
    fprintf('%-28s %s\n', p{k}, string(any(strcmp(installed, p{k}))));
end
```

On R2024b expect Wireless Network Toolbox to report `false` and Communications
Toolbox `true`; check the Wireless Network Simulation Library add-on separately
under Add-On Manager, since it does not appear in `ver`.
