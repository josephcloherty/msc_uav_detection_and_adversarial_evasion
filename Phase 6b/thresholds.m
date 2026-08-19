%% Phase 6 D6.4 - Derive the operating thresholds from pooled out-of-fold scores
%  Reads:  prepared_data/oof_scores.mat and prepared_data/ue_rule.mat
%  Writes: prepared_data/thresholds.mat
%          results/thresholds.csv
%
%  The primary operating point is a 1 per cent false positive rate; 5 per cent is kept
%  as a sensitivity point rather than as an alternative headline. Both are derived at
%  window level and at per-UE level, because the two are different quantities: flagging
%  1 per cent of windows is not the same as flagging 1 per cent of subscribers, and the
%  per-UE rate is the one an operator would be held to.
%
%  Thresholds are read off the pooled out-of-fold scores, so every score used was
%  produced by a model that had not seen the run it came from, and no hold-out data is
%  involved at any point.
%
%  The achieved rate is recorded beside the nominal one throughout. A finite sample
%  cannot in general hit a nominal rate exactly, and at per-UE level the achieved rate
%  can only move in steps of one terrestrial UE, which is coarse enough that quoting the
%  nominal figure alone would misrepresent the result.

%% Settings
clear; clc;
root = fileparts(mfilename('fullpath'));
addpath(root);
U = phase6_util();

nominalFPR = [0.01 0.05];                   % primary first, sensitivity second

load(fullfile(root, 'prepared_data', 'oof_scores.mat'), ...
     'oofScore', 'modelNames', 'modelKeys', 'Ydev', 'ueKeyDev', 'winStartDev', 'posClass');
load(fullfile(root, 'prepared_data', 'ue_rule.mat'), 'chosen');

isPos = (Ydev == posClass);
nM    = numel(modelNames);

rowsOut = cell(0, 9);
winThr  = nan(nM, numel(nominalFPR));
ueThr   = nan(nM, numel(nominalFPR));
ueScoreAll = cell(nM, 1);

for m = 1:nM
    % --- window level ---
    for q = 1:numel(nominalFPR)
        [t, achFPR, rec, nFP, nNeg] = U.pickThreshold(oofScore(:, m), isPos, nominalFPR(q));
        winThr(m, q) = t;
        rowsOut(end+1, :) = {modelNames{m}, 'Window', 'window score', nominalFPR(q), ...
            t, achFPR, rec, nFP, nNeg}; %#ok<SAGROW>
    end

    % --- per-UE level, under the rule selected in D6.3 ---
    S = U.perUEScore(oofScore(:, m), ueKeyDev, winStartDev, isPos, chosen(m));
    ueScoreAll{m} = S;
    for q = 1:numel(nominalFPR)
        [t, achFPR, rec, nFP, nNeg] = U.pickThreshold(S.Score, S.IsPos, nominalFPR(q));
        ueThr(m, q) = t;
        rowsOut(end+1, :) = {modelNames{m}, 'PerUE', U.ruleLabel(chosen(m)), nominalFPR(q), ...
            t, achFPR, rec, nFP, nNeg}; %#ok<SAGROW>
    end
end

T = cell2table(rowsOut, 'VariableNames', ...
    {'Model', 'Level', 'DecisionRule', 'NominalFPR', 'Threshold', ...
     'AchievedFPR', 'Recall', 'FalsePositives', 'NegativeUnits'});
writetable(T, fullfile(root, 'results', 'thresholds.csv'));

%% Report
fprintf('Operating points from pooled out-of-fold scores.\n');
fprintf('Nominal is the target, achieved is what the sample actually delivers.\n\n');
fprintf('%-22s %-7s %-8s %10s %10s %10s %8s\n', ...
    'Model', 'Level', 'Nominal', 'Threshold', 'Achieved', 'Recall', 'FP/neg');
for i = 1:height(T)
    fprintf('%-22s %-7s %7.0f%% %10.4f %9.3f%% %10.3f %4d/%d\n', ...
        T.Model{i}, T.Level{i}, 100 * T.NominalFPR(i), T.Threshold(i), ...
        100 * T.AchievedFPR(i), T.Recall(i), T.FalsePositives(i), T.NegativeUnits(i));
end

%  Recall at the per-UE operating point moves in whole UEs, so ties are common and are
%  reported as ties. Naming whichever family happened to sort first would read as a
%  result and is exactly the claim this phase must not make by accident.
primary = T(T.NominalFPR == 0.01 & strcmp(T.Level, 'PerUE'), :);
best    = primary.Model(primary.Recall == max(primary.Recall));
if numel(best) == 1
    fprintf('\nPrimary operating point, 1%% per-UE FPR, best recall: %s at %.3f.\n', ...
        best{1}, max(primary.Recall));
else
    fprintf(['\nPrimary operating point, 1%% per-UE FPR: %d families tie on best recall at ' ...
             '%.3f (%s).\nRecall alone cannot separate them; D6.7 selects on the partial ' ...
             'AUC.\n'], numel(best), max(primary.Recall), strjoin(best', ', '));
end

save(fullfile(root, 'prepared_data', 'thresholds.mat'), ...
     'winThr', 'ueThr', 'nominalFPR', 'modelNames', 'modelKeys', 'ueScoreAll', 'T');

fprintf('\nSaved results/thresholds.csv and prepared_data/thresholds.mat\n');
fprintf('Run latency_curve.m next.\n');


%% ============================================================================
%% Report outputs
%% ============================================================================
RPT     = report_util();
figDir  = fullfile(root, 'figures');
keyFile = fullfile(root, 'results', 'phase6_key_results.txt');
RPT.ensureDir(figDir);

%% T6.5 / T6.6 Operating points, one table per decision level
levels = {'PerUE', 'Window'};
labels = {'T6.5  Per-UE operating points, fixed on pooled out-of-fold scores', ...
          'T6.6  Window-level operating points, fixed on pooled out-of-fold scores'};
files  = {'T6_5_thresholds_per_ue.png', 'T6_6_thresholds_window.png'};

for L = 1:2
    S = T(strcmp(T.Level, levels{L}), :);
    Tshow = table(string(S.Model), string(S.DecisionRule), 100 * S.NominalFPR, ...
        S.Threshold, 100 * S.AchievedFPR, S.Recall, ...
        strcat(string(S.FalsePositives), " / ", string(S.NegativeUnits)), ...
        'VariableNames', {'Model', 'Decision_rule', 'Nominal_FPR_pct', 'Threshold', ...
                          'Achieved_FPR_pct', 'Recall', 'False_pos_per_negatives'});
    RPT.tableFigure(Tshow, fullfile(figDir, files{L}), struct( ...
        'Title', labels{L}, ...
        'Highlight', S.NominalFPR == 0.01, ...
        'Note', ["";"The 1% rows are the primary operating point; the 5% rows are a sensitivity check."; ...
                 "Achieved is what the finite sample delivers. A nominal rate cannot in general be hit exactly."; ...
                 "No hold-out data is involved: every score here is out-of-fold."]));
end

%% F6.7 What the two operating points buy
recPerUE = zeros(nM, 2);
recWin   = zeros(nM, 2);
for m = 1:nM
    for q = 1:numel(nominalFPR)
        recPerUE(m, q) = T.Recall(strcmp(T.Model, modelNames{m}) & ...
                                  strcmp(T.Level, 'PerUE') & T.NominalFPR == nominalFPR(q));
        recWin(m, q)   = T.Recall(strcmp(T.Model, modelNames{m}) & ...
                                  strcmp(T.Level, 'Window') & T.NominalFPR == nominalFPR(q));
    end
end

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 880 400]);
tl  = tiledlayout(fig, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
mp  = RPT.palette(2);
panels = {recWin, 'Window level'; recPerUE, 'Per-UE level'};
for q = 1:2
    ax = nexttile(tl); hold(ax, 'on');
    bh = bar(ax, panels{q, 1}, 'grouped', 'EdgeColor', 'none');
    for i = 1:numel(bh)
        bh(i).FaceColor = mp(i, :);
        bh(i).FaceAlpha = 0.85;
    end
    set(ax, 'XTick', 1:nM, 'XTickLabel', modelNames);
    xtickangle(ax, 20);
    ylim(ax, [0 1]);
    ylabel(ax, 'Recall');
    title(ax, panels{q, 2});
    if q == 2
        legend(ax, {'at 1% FPR', 'at 5% FPR'}, 'Location', 'northoutside', ...
               'Orientation', 'horizontal', 'Box', 'off');
    end
    RPT.styleAxes(ax);
end
title(tl, 'F6.7  Recall at the two frozen operating points', 'FontWeight', 'bold');
RPT.saveFig(fig, fullfile(figDir, 'F6_7_operating_points.png'));
close(fig);

%% Key results
RPT.logSection(keyFile, 'D6.4  Operating thresholds', [""; ...
    sprintf('Nominal points          : %s', strjoin(cellstr(string(100 * nominalFPR) + "%"), ', ')); ...
    sprintf('Best per-UE recall at 1%%: %.4f (%s)', max(primary.Recall), ...
            strjoin(cellstr(string(best)), ', ')); ...
    "Thresholds are read off pooled out-of-fold scores, never from hold-out data."; ...
    "Achieved rates are reported beside nominal because the per-UE rate moves in whole UE-runs."]);
RPT.logTable(keyFile, T(strcmp(T.Level, 'PerUE'), :), 12);
