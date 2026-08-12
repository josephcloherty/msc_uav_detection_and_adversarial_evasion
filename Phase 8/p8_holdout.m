%% Phase 8 D8.1 - Honest hold-out performance of the five frozen classifiers
%  Reads:  results/scores_ue.csv, results/scores_window.csv, results/thresholds_frozen.csv
%  Writes: results/D81_holdout.csv, results/D81_by_scenario.csv, figures/D81_roc.png
%
%  The headline table for seeds 46 to 60 with the thresholds applied exactly as frozen.
%  Nothing is re-derived from these data: the operating points came from pooled
%  out-of-fold scores in Phase 6 and are read from disk here.
%
%  Every quantity is reported at both observation lengths. The full length is the geometry
%  the models were frozen on and is the honest answer to "how well does this detector
%  work". The truncated length is the baseline every evasive comparison in D8.2 and D8.3
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
assert(~isempty(Uue), 'p8_D1:noHonest', 'No honest rows in the score table; run p8_score.m.');

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
                assert(isscalar(t), 'p8_D1:threshold', ...
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
writetable(T, fullfile(C.resultsDir, 'D81_holdout.csv'));

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
writetable(Tsc, fullfile(C.resultsDir, 'D81_by_scenario.csv'));

%% ROC figure
fig = figure('Position', [100 100 900 400], 'Color', 'w');
cols = V.palette();
tl = tiledlayout(fig, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');

for level = ["Window", "PerUE"]
    ax = nexttile(tl); hold(ax, 'on');
    for m = 1:numel(C.modelNames)
        mdl = string(C.modelNames{m});
        if level == "Window"
            S = Uwn(Uwn.Model == mdl & Uwn.WinIdx <= C.nWin, :);
            sc = S.Score;  ip = S.Label == 1;
        else
            S = Uue(Uue.Model == mdl, :);
            sc = S.ScoreTrunc;  ip = S.Label == 1;
        end
        [x, y] = U.rocCurve(double(ip), sc, 1);
        lw = 1.0 + 1.2 * (m == C.primaryIdx);
        plot(ax, x, y, 'LineWidth', lw, 'Color', cols(min(m, size(cols, 1)), :), ...
             'DisplayName', C.modelNames{m});
    end
    plot(ax, [0 1], [0 1], ':', 'Color', [0.6 0.6 0.6], 'HandleVisibility', 'off');
    xline(ax, 0.01, '--', 'Color', [0.7 0.2 0.2], 'HandleVisibility', 'off');
    xlim(ax, [0 pAUCmax]); ylim(ax, [0 1]);
    xlabel(ax, 'False positive rate'); ylabel(ax, 'True positive rate');
    title(ax, sprintf('%s level, first %d windows', level, C.nWin));
    V.styleAxes(ax);
end
legend(ax, 'Location', 'southeast', 'Box', 'off');
title(tl, sprintf('D8.1 honest hold-out, seeds %d to %d', ...
    min(C.holdoutSeeds), max(C.holdoutSeeds)));
V.saveFig(fig, fullfile(C.figureDir, 'D81_roc.png'));
close(fig);

%% Report
P = T(T.IsPrimary & T.Level == "PerUE" & T.OperatingPoint == string(C.opLabels{C.opIdx}), :);
fprintf('\n----- primary model, %s, per-UE, %s operating point -----\n', ...
    C.primaryName, C.opLabels{C.opIdx});
for i = 1:height(P)
    fprintf('%-10s recall %s   FPR %s   AUC %s\n', P.Length(i), ...
        V.fmtCI(P.TPR(i), P.TPR_lo(i), P.TPR_hi(i)), ...
        V.fmtCI(P.FPR(i), P.FPR_lo(i), P.FPR_hi(i)), ...
        V.fmtCI(P.AUC(i), P.AUC_lo(i), P.AUC_hi(i)));
end
fprintf(['\nThe truncated row is the baseline D8.2 and D8.3 compare against. Any drift ' ...
         'between\nthe two rows is observation length, not evasion.\n']);
fprintf('\nWrote results/D81_holdout.csv, results/D81_by_scenario.csv, figures/D81_roc.png\n');
