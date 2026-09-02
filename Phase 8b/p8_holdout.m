%% Phase 8 D8.1 - Honest hold-out performance of the five frozen classifiers
%  Reads:  results/scores_ue.csv, results/scores_window.csv, results/thresholds_frozen.csv
%  Writes: results/holdout.csv, results/holdout_by_scenario.csv
%          figures/T8_2_holdout_headline.png, figures/T8_3_holdout_primary_lengths.png
%
%  The headline table for seeds 46 to 60 with the thresholds applied exactly as frozen.
%  Nothing is re-derived from these data: the operating points came from pooled
%  out-of-fold scores in Phase 6 and are read from disk here.
%
%  Every quantity is reported at both observation lengths. The full length is the geometry
%  the models were frozen on and is the honest answer to "how well does this detector
%  work". The truncated length is the baseline every evasive comparison in D8.2
%  is drawn against, because the evasive conditions are shorter. Truncation shortens the
%  window sequence a per-UE score averages over, which widens the null distribution of
%  that score and moves the achieved false positive rate away from its nominal value. That
%  movement belongs to the observation length and not to any evasion policy, so quoting
%  the full-length baseline against a truncated condition would charge the evasion for it.
%
%  Intervals are run-level cluster bootstrap, resampling whole simulation runs. With so
%  few aerial UE-runs in the hold-out, and with those unevenly spread across runs, the
%  per-UE intervals are wide and step visibly. That is the evidence the design supports
%  and the table reports it rather than smoothing it.

%% Settings
clear; clc;
C = p8_config();
U = phase6_util();
V = p8_util();

Uue = readtable(C.f.scoresUE,     'TextType', 'string');
Uwn = readtable(C.f.scoresWindow, 'TextType', 'string');
Thr = readtable(fullfile(C.resultsDir, 'thresholds_frozen.csv'), 'TextType', 'string');

Uue = Uue(Uue.Condition == "honest", :);
Uwn = Uwn(Uwn.Condition == "honest", :);
assert(~isempty(Uue), 'p8_holdout:noHonest', 'No honest rows in the score table; run p8_score.m.');

pAUCmax = 0.05;                              % the low false alarm region, as in Phase 6
rows = {};

fprintf('===== D8.1 honest hold-out =====\n');
fprintf('Runs %d, UE-runs %d, aerial %d. Truncation %d windows.\n\n', ...
    numel(unique(Uue.RunKey)), numel(unique(Uue.UEKey)) , ...
    sum(Uue.Label == 1 & Uue.Model == string(C.modelNames{1})), C.nWin);

for m = 1:numel(C.modelNames)
    mdl = string(C.modelNames{m});

    for level = ["Window", "PerUE"]
        for len = ["Full", "Truncated"]

            % --- assemble the scores for this cell of the table ---
            if level == "Window"
                S = Uwn(Uwn.Model == mdl, :);
                if len == "Truncated", S = S(S.WinIdx <= C.nWin, :); end
                score = S.Score;   isPos = S.Label == 1;   runKey = S.RunKey;
                nUnits = height(S);
            else
                S = Uue(Uue.Model == mdl, :);
                if len == "Full"
                    score = S.ScoreFull;
                else
                    score = S.ScoreTrunc;
                end
                isPos = S.Label == 1;   runKey = S.RunKey;
                nUnits = height(S);
            end

            % --- threshold-free metrics ---
            [x, y, auc] = U.rocCurve(double(isPos), score, 1);
            [~, pAUCn]  = U.partialAUC(x, y, pAUCmax);

            aucStat = @(idx) V.aucOf(isPos(idx), score(idx));
            [~, aucLo, aucHi] = V.clusterBoot(runKey, aucStat, C.nBoot, C.bootSeed, C.ciLevel);

            % --- metrics at each frozen operating point ---
            for q = 1:numel(C.opLabels)
                t = Thr.Threshold(Thr.Model == mdl & Thr.Level == level & ...
                                  Thr.OperatingPoint == string(C.opLabels{q}));
                assert(isscalar(t), 'p8_holdout:threshold', ...
                    'Expected one frozen threshold for %s / %s / %s.', mdl, level, C.opLabels{q});

                pt = V.metricsAt(score, isPos, t);

                tprStat = @(idx) V.tprAt(score(idx), isPos(idx), t);
                fprStat = @(idx) V.fprAt(score(idx), isPos(idx), t);
                [~, tprLo, tprHi] = V.clusterBoot(runKey, tprStat, C.nBoot, C.bootSeed, C.ciLevel);
                [~, fprLo, fprHi] = V.clusterBoot(runKey, fprStat, C.nBoot, C.bootSeed, C.ciLevel);

                rows{end+1} = {mdl, string(level), string(len), string(C.opLabels{q}), ...
                    t, nUnits, pt.nPos, pt.nNeg, ...
                    auc, aucLo, aucHi, pAUCn, ...
                    pt.TPR, tprLo, tprHi, pt.FPR, fprLo, fprHi, ...
                    pt.Precision, pt.F1, pt.TP, pt.FP, pt.FN, pt.TN, ...
                    m == C.primaryIdx}; %#ok<SAGROW>
            end
        end
    end
    fprintf('%-22s done\n', mdl);
end

T = cell2table(vertcat(rows{:}), 'VariableNames', ...
    {'Model', 'Level', 'Length', 'OperatingPoint', 'Threshold', 'Units', 'nPos', 'nNeg', ...
     'AUC', 'AUC_lo', 'AUC_hi', 'pAUC5norm', ...
     'TPR', 'TPR_lo', 'TPR_hi', 'FPR', 'FPR_lo', 'FPR_hi', ...
     'Precision', 'F1', 'TP', 'FP', 'FN', 'TN', 'IsPrimary'});
writetable(T, fullfile(C.resultsDir, 'holdout.csv'));

%% Per-scenario breakdown
%  Supporting evidence, not a headline. Five seeds each of three deployment scenarios is
%  too few for an interval, so point estimates only. The purpose is to show the pooled
%  result is not carried by one deployment type, which is the first thing an examiner will
%  ask and the cheapest thing to answer.
scRows = {};
for m = 1:numel(C.modelNames)
    mdl = string(C.modelNames{m});
    S = Uue(Uue.Model == mdl, :);
    t = Thr.Threshold(Thr.Model == mdl & Thr.Level == "PerUE" & ...
                      Thr.OperatingPoint == string(C.opLabels{C.opIdx}));
    for sc = unique(S.Scenario)'
        P = S(S.Scenario == sc, :);
        pt = V.metricsAt(P.ScoreTrunc, P.Label == 1, t);
        scRows{end+1} = {mdl, sc, numel(unique(P.RunKey)), pt.nPos, pt.nNeg, ...
            pt.TPR, pt.FPR, pt.TP, pt.FP}; %#ok<SAGROW>
    end
end
Tsc = cell2table(vertcat(scRows{:}), 'VariableNames', ...
    {'Model', 'Scenario', 'Runs', 'AerialUERuns', 'TerrestrialUERuns', ...
     'TPR', 'FPR', 'TP', 'FP'});
writetable(Tsc, fullfile(C.resultsDir, 'holdout_by_scenario.csv'));


%% Report
P = T(T.IsPrimary & T.Level == "PerUE" & T.OperatingPoint == string(C.opLabels{C.opIdx}), :);
fprintf('\n----- primary model, %s, per-UE, %s operating point -----\n', ...
    C.primaryName, C.opLabels{C.opIdx});
for i = 1:height(P)
    fprintf('%-10s detected %-18s  false alarms %-18s  AUC %s\n', P.Length(i), ...
        V.fmtCountCI(P.TP(i), P.nPos(i)), V.fmtCountCI(P.FP(i), P.nNeg(i)), ...
        V.fmtCI(P.AUC(i), P.AUC_lo(i), P.AUC_hi(i)));
end
fprintf(['\nCounts are UE-runs. The bracketed range is the Clopper-Pearson 95%% interval\n' ...
         'converted back to UE-runs: the exact binomial interval, which unlike a bootstrap\n' ...
         'still reports a bound when every unit is classified the same way.\n']);
fprintf(['\nThe truncated row is the baseline D8.2 compares against. Any drift between the\n' ...
         'two rows is observation length, not evasion.\n']);
fprintf('\nWrote results/holdout.csv and results/holdout_by_scenario.csv\n');


%% ============================================================================
%% Report outputs
%% ============================================================================
RPT     = report_util();
figDir  = C.figureDir;
keyFile = fullfile(C.resultsDir, 'phase8_key_results.txt');
RPT.ensureDir(figDir);
opLab   = string(C.opLabels{C.opIdx});

%% T8.2 The headline: every family at the frozen per-UE operating point
Hh = T(T.Level == "PerUE" & T.Length == "Truncated" & T.OperatingPoint == opLab, :);
Hh = sortrows(Hh, 'AUC', 'descend');
aucTxt = strings(height(Hh), 1);
detTxt = strings(height(Hh), 1);
falTxt = strings(height(Hh), 1);
for i = 1:height(Hh)
    aucTxt(i) = RPT.fmtCI(Hh.AUC(i), Hh.AUC_lo(i), Hh.AUC_hi(i));
    detTxt(i) = V.fmtCountCI(Hh.TP(i), Hh.nPos(i));
    falTxt(i) = V.fmtCountCI(Hh.FP(i), Hh.nNeg(i));
end
T82 = table(Hh.Model, aucTxt, Hh.pAUC5norm, detTxt, falTxt, Hh.FN, ...
    'VariableNames', {'Model', 'AUC_95pct_CI', 'pAUC_below_5pct', ...
                      'Aerial_detected', 'Terrestrial_flagged', 'Aerial_missed'});

RPT.tableFigure(T82, fullfile(figDir, 'T8_2_holdout_headline.png'), struct( ...
    'Title', sprintf('T8.2  D8.1 honest hold-out, per-UE, %s, first %d windows', opLab, C.nWin), ...
    'Highlight', Hh.IsPrimary, ...
    'Note', ["";sprintf('Seeds %d to %d. %d aerial and %d terrestrial UE-runs. Thresholds applied exactly as frozen.', ...
                     min(C.holdoutSeeds), max(C.holdoutSeeds), Hh.nPos(1), Hh.nNeg(1)); ...
             "Counts of UE-runs, not rates: one aerial UE-run is four points of recall on this sample."; ...
             "Bracketed ranges are exact Clopper-Pearson 95 per cent intervals converted back to UE-runs."; ...
             "Clopper-Pearson rather than the bootstrap, because at 25 of 25 the bootstrap has no spread to resample."]));

%% T8.3 The primary family at both observation lengths and both levels
Pp = T(T.IsPrimary & T.OperatingPoint == opLab, :);
detTxt = strings(height(Pp), 1);
falTxt = strings(height(Pp), 1);
aucTxt = strings(height(Pp), 1);
for i = 1:height(Pp)
    detTxt(i) = V.fmtCountCI(Pp.TP(i), Pp.nPos(i));
    falTxt(i) = V.fmtCountCI(Pp.FP(i), Pp.nNeg(i));
    aucTxt(i) = RPT.fmtCI(Pp.AUC(i), Pp.AUC_lo(i), Pp.AUC_hi(i));
end
T83 = table(Pp.Level, Pp.Length, Pp.Threshold, aucTxt, detTxt, falTxt, ...
    'VariableNames', {'Level', 'Observation_length', 'Frozen_threshold', ...
                      'AUC_95pct_CI', 'Detected', 'Falsely_flagged'});

RPT.tableFigure(T83, fullfile(figDir, 'T8_3_holdout_primary_lengths.png'), struct( ...
    'Title', sprintf('T8.3  %s at both observation lengths, %s', C.primaryName, opLab), ...
    'Highlight', Pp.Level == "PerUE" & Pp.Length == "Truncated", ...
    'Note', ["";"Full is the geometry the models were frozen on and is the honest answer to how well the detector works."; ...
             "Truncated is the baseline every evasive comparison in D8.2 is drawn against."; ...
             "At full length the frozen threshold gives one false alarm in 120; the truncated rise is observation length, not evasion."; ...
             "A shorter observation averages fewer windows, which widens the null distribution of the per-UE score."]));

%% Key results
Pr = Hh(Hh.IsPrimary, :);
Pf = T(T.IsPrimary & T.Level == "PerUE" & T.Length == "Full" & T.OperatingPoint == opLab, :);
RPT.logSection(keyFile, 'D8.1  Honest hold-out', [""; ...
    sprintf('Primary model          : %s', C.primaryName); ...
    sprintf('Per-UE AUC             : %s', RPT.fmtCI(Pr.AUC, Pr.AUC_lo, Pr.AUC_hi)); ...
    sprintf('Aerial detected, full  : %s UE-runs', V.fmtCountCI(Pf.TP, Pf.nPos)); ...
    sprintf('False alarms, full     : %s UE-runs', V.fmtCountCI(Pf.FP, Pf.nNeg)); ...
    sprintf('Aerial detected, trunc : %s UE-runs', V.fmtCountCI(Pr.TP, Pr.nPos)); ...
    sprintf('False alarms, trunc    : %s UE-runs', V.fmtCountCI(Pr.FP, Pr.nNeg)); ...
    sprintf('Aerial missed          : %d of %d', Pr.FN, Pr.nPos); ...
    'Intervals are exact Clopper-Pearson, converted to UE-runs'; ...
    sprintf('Best AUC of the five   : %s at %.4f', Hh.Model(1), Hh.AUC(1))]);
RPT.logTable(keyFile, T82, 8);
%  The per-scenario split for the honest condition is logged from Tsc rather than drawn.
%  D8.2's F8.5 shows the same breakdown with the evasion conditions alongside, which is
%  the version worth a figure; a separate honest-only chart would repeat one of its bars.
Sc = Tsc(Tsc.Model == string(C.primaryName), :);
RPT.logSection(keyFile, 'D8.1  By deployment scenario, primary model', ...
    [""; arrayfun(@(i) sprintf('%-6s detected %d of %d, falsely flagged %d of %d', ...
        Sc.Scenario(i), Sc.TP(i), Sc.AerialUERuns(i), Sc.FP(i), Sc.TerrestrialUERuns(i)), ...
        (1:height(Sc))', 'UniformOutput', false)]);
