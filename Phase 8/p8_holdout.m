%% Phase 8 D8.1 - Honest hold-out performance of the five frozen classifiers
%  Reads:  results/scores_ue.csv, results/scores_window.csv, results/thresholds_frozen.csv
%  Writes: results/holdout.csv, results/holdout_by_scenario.csv, figures/holdout_roc.png
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
V.saveFig(fig, fullfile(C.figureDir, 'holdout_roc.png'));
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
fprintf('\nWrote results/holdout.csv, results/holdout_by_scenario.csv, figures/holdout_roc.png\n');


%% ============================================================================
%% Report outputs
%% ============================================================================
RPT     = report_util();
figDir  = C.figureDir;
keyFile = fullfile(C.resultsDir, 'phase8_key_results.txt');
RPT.ensureDir(figDir);
opLab   = string(C.opLabels{C.opIdx});
palM    = RPT.palette(numel(C.modelNames));

%% T8.2 The headline: every family at the frozen per-UE operating point
Hh = T(T.Level == "PerUE" & T.Length == "Truncated" & T.OperatingPoint == opLab, :);
Hh = sortrows(Hh, 'AUC', 'descend');
aucTxt = strings(height(Hh), 1);
tprTxt = strings(height(Hh), 1);
fprTxt = strings(height(Hh), 1);
for i = 1:height(Hh)
    aucTxt(i) = RPT.fmtCI(Hh.AUC(i), Hh.AUC_lo(i), Hh.AUC_hi(i));
    tprTxt(i) = RPT.fmtCI(Hh.TPR(i), Hh.TPR_lo(i), Hh.TPR_hi(i));
    fprTxt(i) = RPT.fmtCI(Hh.FPR(i), Hh.FPR_lo(i), Hh.FPR_hi(i), 4);
end
T82 = table(Hh.Model, aucTxt, Hh.pAUC5norm, tprTxt, fprTxt, Hh.TP, Hh.FP, Hh.FN, ...
    'VariableNames', {'Model', 'AUC_95pct_CI', 'pAUC_below_5pct', ...
                      'Recall_95pct_CI', 'FPR_95pct_CI', 'TP', 'FP', 'FN'});

RPT.tableFigure(T82, fullfile(figDir, 'T8_2_holdout_headline.png'), struct( ...
    'Title', sprintf('T8.2  D8.1 honest hold-out, per-UE, %s, first %d windows', opLab, C.nWin), ...
    'Highlight', Hh.IsPrimary, ...
    'Note', ["";sprintf('Seeds %d to %d, %d aerial and %d terrestrial UE-runs. Thresholds applied exactly as frozen.', ...
                     min(C.holdoutSeeds), max(C.holdoutSeeds), Hh.nPos(1), Hh.nNeg(1)); ...
             sprintf('Intervals are a %d-resample cluster bootstrap over whole simulation runs.', C.nBoot); ...
             sprintf('Recall moves in steps of 1/%d = %.1f percentage points, so read the interval, not the point.', ...
                     Hh.nPos(1), 100 / Hh.nPos(1))]));

%% T8.3 The primary family at both observation lengths and both levels
Pp = T(T.IsPrimary & T.OperatingPoint == opLab, :);
tprTxt = strings(height(Pp), 1);
fprTxt = strings(height(Pp), 1);
aucTxt = strings(height(Pp), 1);
for i = 1:height(Pp)
    tprTxt(i) = RPT.fmtCI(Pp.TPR(i), Pp.TPR_lo(i), Pp.TPR_hi(i));
    fprTxt(i) = RPT.fmtCI(Pp.FPR(i), Pp.FPR_lo(i), Pp.FPR_hi(i), 4);
    aucTxt(i) = RPT.fmtCI(Pp.AUC(i), Pp.AUC_lo(i), Pp.AUC_hi(i));
end
T83 = table(Pp.Level, Pp.Length, Pp.Threshold, Pp.Units, aucTxt, tprTxt, fprTxt, ...
    'VariableNames', {'Level', 'Observation_length', 'Frozen_threshold', 'Units', ...
                      'AUC_95pct_CI', 'Recall_95pct_CI', 'FPR_95pct_CI'});

RPT.tableFigure(T83, fullfile(figDir, 'T8_3_holdout_primary_lengths.png'), struct( ...
    'Title', sprintf('T8.3  %s at both observation lengths, %s', C.primaryName, opLab), ...
    'Highlight', Pp.Level == "PerUE" & Pp.Length == "Truncated", ...
    'Note', ["";"Full is the geometry the models were frozen on and is the honest answer to how well the detector works."; ...
             "Truncated is the baseline every evasive comparison in D8.2 and D8.3 is drawn against."; ...
             "Drift between the two rows is observation length, not evasion. The highlighted row is the reference."]));

%% F8.1 Every family, three quantities, with intervals
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 940 380]);
tl  = tiledlayout(fig, 1, 3, 'Padding', 'compact', 'TileSpacing', 'compact');
spec = {'AUC', 'AUC_lo', 'AUC_hi', 'Area under the ROC'; ...
        'TPR', 'TPR_lo', 'TPR_hi', sprintf('Recall at %s', opLab); ...
        'FPR', 'FPR_lo', 'FPR_hi', sprintf('False positive rate at %s', opLab)};
for q = 1:3
    ax = nexttile(tl); hold(ax, 'on');
    v  = Hh.(spec{q, 1});
    lo = Hh.(spec{q, 2});
    hi = Hh.(spec{q, 3});
    for i = 1:height(Hh)
        if Hh.IsPrimary(i), col = [0.85 0.37 0.01]; else, col = [0.35 0.45 0.60]; end
        bar(ax, i, v(i), 0.6, 'FaceColor', col, 'FaceAlpha', 0.88, 'EdgeColor', 'none');
    end
    errorbar(ax, 1:height(Hh), v, v - lo, hi - v, 'k', 'LineStyle', 'none', ...
             'LineWidth', 0.9, 'CapSize', 3);
    if q == 3
        nomFPR = Thr.NominalFPR(find(Thr.OperatingPoint == opLab, 1));
        yline(ax, nomFPR, '--', 'Color', [0.7 0.2 0.2], 'Label', 'nominal', ...
              'FontSize', 8, 'LabelHorizontalAlignment', 'left');
    end
    set(ax, 'XTick', 1:height(Hh), 'XTickLabel', Hh.Model);
    xtickangle(ax, 25);
    ylabel(ax, spec{q, 4});
    title(ax, spec{q, 4});
    RPT.styleAxes(ax);
end
title(tl, sprintf('F8.1  Honest hold-out, per-UE level, first %d windows (primary in orange)', C.nWin), ...
      'FontWeight', 'bold');
RPT.saveFig(fig, fullfile(figDir, 'F8_1_holdout_model_comparison.png'));
close(fig);

%% F8.2 Is the result carried by one deployment scenario
scens = unique(Tsc.Scenario);
mdls  = string(C.modelNames);
recM  = nan(numel(scens), numel(mdls));
for s = 1:numel(scens)
    for m = 1:numel(mdls)
        v = Tsc.TPR(Tsc.Scenario == scens(s) & Tsc.Model == mdls(m));
        if ~isempty(v), recM(s, m) = v(1); end
    end
end
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 760 400]);
ax  = axes('Parent', fig); hold(ax, 'on');
bh  = bar(ax, recM, 'grouped', 'EdgeColor', 'none');
for m = 1:numel(bh)
    bh(m).FaceColor = palM(m, :);
    bh(m).FaceAlpha = 0.88;
end
set(ax, 'XTick', 1:numel(scens), 'XTickLabel', cellstr(scens));
ylim(ax, [0 1]);
ylabel(ax, sprintf('Per-UE recall at %s', opLab));
legend(ax, C.modelNames, 'Location', 'northoutside', 'Orientation', 'horizontal', ...
       'Box', 'off', 'FontSize', 8);
title(ax, 'F8.2  Hold-out recall by deployment scenario', 'FontSize', 11, 'FontWeight', 'bold');
RPT.styleAxes(ax);
RPT.saveFig(fig, fullfile(figDir, 'F8_2_holdout_by_scenario.png'));
close(fig);

%% T8.4 The per-scenario table behind it, primary family only
Sc = Tsc(Tsc.Model == string(C.primaryName), :);
T84 = table(Sc.Scenario, Sc.Runs, Sc.AerialUERuns, Sc.TerrestrialUERuns, ...
    Sc.TPR, Sc.FPR, Sc.TP, Sc.FP, ...
    'VariableNames', {'Scenario', 'Runs', 'Aerial_UE_runs', 'Terrestrial_UE_runs', ...
                      'Recall', 'FPR', 'TP', 'FP'});
RPT.tableFigure(T84, fullfile(figDir, 'T8_4_holdout_by_scenario.png'), struct( ...
    'Title', sprintf('T8.4  %s by deployment scenario, %s', C.primaryName, opLab), ...
    'Note', ["";"Five seeds per scenario is too few for an interval, so these are point estimates."; ...
             "The purpose is to show the pooled result is not carried by one deployment type."]));

%% Key results
Pr = Hh(Hh.IsPrimary, :);
RPT.logSection(keyFile, 'D8.1  Honest hold-out', [""; ...
    sprintf('Primary model          : %s', C.primaryName); ...
    sprintf('Per-UE AUC             : %s', RPT.fmtCI(Pr.AUC, Pr.AUC_lo, Pr.AUC_hi)); ...
    sprintf('Per-UE recall at %s : %s', opLab, RPT.fmtCI(Pr.TPR, Pr.TPR_lo, Pr.TPR_hi)); ...
    sprintf('Per-UE FPR at %s    : %s', opLab, RPT.fmtCI(Pr.FPR, Pr.FPR_lo, Pr.FPR_hi, 4)); ...
    sprintf('Confusion              : TP %d, FP %d, FN %d, TN %d', Pr.TP, Pr.FP, Pr.FN, Pr.TN); ...
    sprintf('Aerial / terrestrial   : %d / %d UE-runs', Pr.nPos, Pr.nNeg); ...
    sprintf('Best AUC of the five   : %s at %.4f', Hh.Model(1), Hh.AUC(1))]);
RPT.logTable(keyFile, T82, 8);
RPT.logSection(keyFile, 'D8.1  By deployment scenario, primary model', "");
RPT.logTable(keyFile, T84, 6);
