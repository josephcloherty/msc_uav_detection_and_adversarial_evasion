# 7 July 2026

## Logbook

- Analysed the exported 20 s UMa diagnostics: verified the windowed CSV byte-for-byte against an independent recomputation, confirmed mobility and scan cadence are correct, and traced the stacked-first-frame replay artefact to an empty-array append bug in the position recorder, now fixed. Identified two design-level effects for follow-up: uplink SINR saturation near 32 dB making the 1 dB A3 hysteresis noise-dominated, and a systematic bias against the common physical anchor cell.
- Extended the diagnostics export with a full per-link record (geometry, LOS draw and probability, both pathloss branches, ZOD offset, shadow fading, channel seed and fast-fading parameters per gNB-UE pair) plus the new per-scan per-gNB SINR log, and rebuilt the replay plot dialog around a derived-series registry so any combination of some twenty-plus per-UE series can be multi-selected into one multi-panel figure.
- Replaced the instant A3 handover rule with the TS 36.331 measurement chain using the TR 36.777 Table A.2.1-1 baseline (L1 200 ms and L3 k=1 filtering, 2 dB A3 offset, 160 ms time-to-trigger, 50 ms plus 40 ms handover delays, 1.22 dB measurement error, 1 s minimum-time-of-stay ping-pong metric), with the legacy rule kept switchable and the dataset feature definitions unchanged.

- Removed the Phase 2 geometric building-blockage add-on from the Phase 3 pipeline so LOS and NLOS behaviour comes entirely from the statistical TR 36.777 / TR 38.901 models, avoiding double-counted obstruction (deviations log). Added settle-time gating so scans and handovers from the distance-based initial attach are excluded from the windowed dataset.
- Extended the replay tool for Phase 3 runs while keeping Phase 2 saves loadable: saved replays now carry the scenario config and link states, serving lines are coloured by LOS state and annotated in the 3D view with the live LOS probability, geometric ZoD and ZOD offset, and the readout shows the sliding-window features with the UE's window trail drawn on the map.
- Added a replay start-up cull, tied to the settle gate, so the viewer drops the whole settle span and re-zeroes its clock: settle-gated data now appears neither in the dataset nor in replays, and playback opens after the initial attach and handover burst rather than with all UEs at their spawn points. Made the window trail a solid gold indicator with the window span shown in the title, and made labels theme-aware so they stay readable in dark mode.

Deliverables completed: none closed this session; D3.1 to D3.4 remain code complete pending the MATLAB verification runs.

# 6 July 2026

## Logbook

- Verified every TR 36.777 aerial overlay parameter directly against the two source .doc parts by extracting the embedded equation objects, covering Tables B-1, B-2, B-3, B.1.1-1, B.1.1-2 and the ZOD offset equations B.1.1-1 and B.1.1-2. Cross-checked the terrestrial baselines (LOS probability Table 7.4.2-1, CDL-D Table 7.7.1-4, scaling clauses 7.7.3, 7.7.5.1 and 7.7.6, delay spreads Table 7.5-6) against the TR 38.901 source document.
- Implemented the D3.1 core pipeline: per-UE sliding-window feature extraction (10 s window over the SRS-based per-gNB SINR logs: serving SINR mean and variance, neighbour SINR statistics, count of gNBs above threshold, windowed handover count, mean inter-handover interval) with the locked CSV schema defined in one place (phase3FeatureSchema.m). The schema carries scenario, seed and the 0/1 terrestrial/aerial label from the start, and the writer prints fixed-format values so a fixed seed regenerates the file byte for byte.
- Implemented the D3.2 UMa fork: TR 38.901 UMa terrestrial paired with the TR 36.777 UMa-AV overlay (22.5 m boundary, Table B.1.1-2 CDL-D scaling, rooftop-reflection ZOD offset), as the scenario script phase3_UMa.m over the shared pipeline. A before/after validation figure script (validateAerialOverlay.m) compares pathloss, LOS probability, cluster ZOD and the power delay profile with and without the overlay.
- Implemented the D3.3 RMa fork as a configuration-only scenario script (10 m boundary, Table B.1.1-1 parameters, ground-reflection ZOD offset), sharing the pipeline, channel builder and schema unchanged. The same validation figure script covers the RMa before/after evidence.
- Confirmed from the TR 36.777 source that UMi-AV Alternative 1 is not CDL-D based but a reverse-UMa reuse of the clause 7.5 model with the BS and UE angular spreads interchanged, correcting the earlier project documentation (see deviations log). Implemented the D3.4 UMi fork in its own folder with a clause 7.5 cluster-generation builder (buildUMiAVChannel.m), its scenario script and its own validation figure script.

Deliverables completed: D3.1, D3.2, D3.3 and D3.4 code complete with validation figure scripts; the fixed-seed CSV regeneration check and the validation figure runs still need to be executed in MATLAB.
