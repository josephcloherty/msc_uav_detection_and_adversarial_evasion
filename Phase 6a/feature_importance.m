%% Phase 6 D6.6 - Feature importance against literature expectations
%  Reads:  prepared_data/phase6_data.mat, prepared_data/oof_scores.mat,
%          prepared_data/leakage_check.csv, results/literature_expectations.csv
%  Writes: results/feature_importance.csv and results/feature_importance.png
%          results/literature_expectations.csv is created as a template if absent
%
%  Four views of the same question, because no single importance measure is neutral.
%  Out-of-bag permutation importance rewards a feature the forest actually splits on;
%  a linear coefficient rewards a feature with a monotone marginal effect; a single
%  feature AUC ignores interactions entirely. A feature that ranks high on all four is
%  carrying discriminative load in a way that does not depend on the choice of measure.
%
%  Importance is measured on the same folds as D6.2, refitting within each fold, so the
%  dispersion column is a statement about how stable the ranking is across runs rather
%  than a single number from a single fit.
%
%  The literature and manipulability columns are read from an editable CSV rather than
%  hard-coded. The manipulability judgement is the one that decides whether a feature is
%  usable in deployment: a detector resting on features a UE controls can be defeated by
%  the UE, however well it scores here.

%% Settings
clear; clc;
rng(9999);
root = fileparts(mfilename('fullpath'));
addpath(root);
U = phase6_util();
litFile = fullfile(root, 'results', 'literature_expectations.csv');

load(fullfile(root, 'prepared_data', 'phase6_data.mat'), ...
     'Xdev', 'Ydev', 'featureNames', 'posClass');
load(fullfile(root, 'prepared_data', 'oof_scores.mat'), 'foldOfRow', 'K');

nF = numel(featureNames);
oobImp  = nan(nF, K);
treeImp = nan(nF, K);
logCoef = nan(nF, K);
discCoef = nan(nF, K);

%% Measure importance fold by fold
for f = 1:K
    tr = foldOfRow ~= f;
    Xtr = Xdev(tr, :);  Ytr = Ydev(tr);

    med = median(Xtr, 1, 'omitnan');
    med(isnan(med)) = 0;
    Xtr = U.imputeWith(Xtr, med);

    mu = mean(Xtr, 1);  sg = std(Xtr, 0, 1);  sg(sg == 0) = 1;
    Ztr = (Xtr - mu) ./ sg;

    numVars = max(1, round(sqrt(nF)));
    rf = fitcensemble(Xtr, Ytr, 'Method', 'Bag', 'NumLearningCycles', 100, ...
        'Learners', templateTree('NumVariablesToSample', numVars, 'Reproducible', true));
    oobImp(:, f) = oobPermutedPredictorImportance(rf)';

    tree = fitctree(Xtr, Ytr, 'MaxNumSplits', 100, 'MinLeafSize', 20);
    treeImp(:, f) = predictorImportance(tree)';

    % Standardised predictors, so the coefficient magnitude is directly comparable
    % across features and is a like-for-like ranking rather than a units artefact.
    lg = fitclinear(Ztr, Ytr, 'Learner', 'logistic');
    logCoef(:, f) = abs(lg.Beta);

    da = fitcdiscr(Ztr, Ytr, 'DiscrimType', 'pseudoLinear');
    discCoef(:, f) = abs(da.Coeffs(1, 2).Linear);

    fprintf('Fold %d of %d measured.\n', f, K);
end

%% Single-feature separability, already computed by prepare_data.m
leak = readtable(fullfile(root, 'prepared_data', 'leakage_check.csv'));
[tf, loc] = ismember(featureNames(:), leak.Feature);
assert(all(tf), 'feature_importance:missingLeakRow', ...
    'leakage_check.csv does not cover every predictor; rerun prepare_data.m.');
singleAUC = leak.SingleFeatureAUC(loc);

%% Combine into one ranking
%  Each measure is turned into a rank and the ranks averaged, because the four are on
%  incomparable scales and averaging the raw values would let whichever has the widest
%  range decide the outcome on its own.
measures = [mean(oobImp, 2), mean(treeImp, 2), mean(logCoef, 2), ...
            mean(discCoef, 2), singleAUC];
ranks = nan(size(measures));
for c = 1:size(measures, 2)
    [~, ord] = sort(measures(:, c), 'descend');
    ranks(ord, c) = 1:nF;
end
meanRank = mean(ranks, 2);
[~, finalOrd] = sort(meanRank, 'ascend');

F = table(featureNames(finalOrd)', meanRank(finalOrd), ...
    mean(oobImp(finalOrd, :), 2), std(oobImp(finalOrd, :), 0, 2), ...
    mean(treeImp(finalOrd, :), 2), ...
    mean(logCoef(finalOrd, :), 2), std(logCoef(finalOrd, :), 0, 2), ...
    mean(discCoef(finalOrd, :), 2), singleAUC(finalOrd), ...
    ranks(finalOrd, 1), ranks(finalOrd, 3), ranks(finalOrd, 5), ...
    'VariableNames', {'Feature', 'MeanRank', ...
    'RF_OOBImportance_mean', 'RF_OOBImportance_sd', 'Tree_SplitImportance_mean', ...
    'Logistic_absCoef_mean', 'Logistic_absCoef_sd', 'Discriminant_absCoef_mean', ...
    'SingleFeatureAUC', 'Rank_RF', 'Rank_Logistic', 'Rank_SingleAUC'});

%% Join the literature expectation and manipulability judgement
if ~isfile(litFile)
    U.writeLiteratureTemplate(litFile, featureNames);
    fprintf('\nCreated results/literature_expectations.csv as a template.\n');
    fprintf('The expectation and source columns are marked REVIEW and are yours to fill in.\n');
end
lit = readtable(litFile, 'TextType', 'string');
[tf, loc] = ismember(string(F.Feature), lit.Feature);
missing = F.Feature(~tf);
if ~isempty(missing)
    fprintf('\nNote: %d predictor(s) absent from literature_expectations.csv: %s\n', ...
        numel(missing), strjoin(missing, ', '));
end
blank = repmat("", height(F), 1);
F.FeatureBlock         = blank;  F.FeatureBlock(tf)         = lit.FeatureBlock(loc(tf));
F.LiteratureExpectation = blank; F.LiteratureExpectation(tf) = lit.LiteratureExpectation(loc(tf));
F.Source               = blank;  F.Source(tf)               = lit.Source(loc(tf));
F.Manipulability       = blank;  F.Manipulability(tf)       = lit.Manipulability(loc(tf));

writetable(F, fullfile(root, 'results', 'feature_importance.csv'));

%% Report
fprintf('\n%-26s %6s %10s %10s %10s %-16s %s\n', ...
    'Feature', 'Rank', 'RF OOB', '|logit|', 'SingleAUC', 'Block', 'Manipulability');
for i = 1:height(F)
    fprintf('%-26s %6.1f %10.3f %10.3f %10.3f %-16s %s\n', ...
        F.Feature{i}, F.MeanRank(i), F.RF_OOBImportance_mean(i), ...
        F.Logistic_absCoef_mean(i), F.SingleFeatureAUC(i), ...
        F.FeatureBlock(i), F.Manipulability(i));
end

lowMan = F(F.Manipulability == "Low", :);
fprintf('\nOf the top five by mean rank, %d sit in feature blocks judged hard for a UE to manipulate.\n', ...
    sum(ismember(F.Feature(1:min(5, height(F))), lowMan.Feature)));

%% Figure
fig = figure('Visible', 'off', 'Position', [100 100 800 max(300, 22 * nF)]);
barh(flipud(mean(oobImp(finalOrd, :), 2)));
set(gca, 'YTick', 1:nF, 'YTickLabel', flipud(F.Feature), 'TickLabelInterpreter', 'none');
xlabel('Out-of-bag permuted importance, mean over folds');
title('Feature importance, ordered by mean rank across four measures');
grid on;
RPT0 = report_util();          % white background, black text, whatever theme is active
RPT0.saveFig(fig, fullfile(root, 'results', 'feature_importance.png'));
close(fig);

fprintf('\nSaved results/feature_importance.csv and results/feature_importance.png\n');
fprintf('Run freeze_models.m next.\n');


%% ============================================================================
%% Report outputs
%% ============================================================================
RPT     = report_util();
figDir  = fullfile(root, 'figures');
keyFile = fullfile(root, 'results', 'phase6_key_results.txt');
RPT.ensureDir(figDir);

%% T6.8 The ranking, with the judgement that decides deployability
Timp = table(string(F.Feature), F.MeanRank, F.RF_OOBImportance_mean, ...
    F.Logistic_absCoef_mean, F.SingleFeatureAUC, F.FeatureBlock, F.Manipulability, ...
    'VariableNames', {'Predictor', 'Mean_rank', 'RF_OOB_importance', ...
                      'Logistic_abs_coef', 'Single_feature_AUC', 'Feature_block', ...
                      'Manipulability'});

RPT.tableFigure(Timp, fullfile(figDir, 'T6_8_feature_importance.png'), struct( ...
    'Title', 'T6.8  Predictor importance, ranked across four independent measures', ...
    'Highlight', F.MeanRank <= 5, ...
    'Note', ["";"Mean rank averages the ranks from four measures, because they sit on incomparable scales."; ...
             "Manipulability is the judgement that decides deployability: a detector resting on features"; ...
             "a UE controls can be defeated by the UE, however well it scores here."; ...
             "Blank block and manipulability columns mean results/literature_expectations.csv is unfilled."]));

%% F6.9 Where each measure puts each predictor
%  Four measures, one ranking each. A predictor that is high on all of them is carrying
%  discriminative load in a way that does not depend on the choice of measure.
rankShow = ranks(finalOrd, [1 2 3 4 5]);
measLbl  = {'RF OOB permuted', 'Tree split', 'Logistic |coef|', 'Discriminant |coef|', 'Single-feature AUC'};

fig = figure('Visible', 'off', 'Color', 'w', ...
             'Position', [100 100 620, 130 + 34 * nF]);
ax = axes('Parent', fig);
imagesc(ax, rankShow, [1 nF]);
cmap = flipud([linspace(0.13, 1, 256)', linspace(0.30, 1, 256)', linspace(0.55, 1, 256)']);
colormap(ax, cmap);
set(ax, 'XTick', 1:numel(measLbl), 'XTickLabel', measLbl, ...
        'YTick', 1:nF, 'YTickLabel', F.Feature, 'TickLabelInterpreter', 'none', ...
        'FontName', 'Helvetica', 'FontSize', 8, 'TickDir', 'out');
xtickangle(ax, 25);
cb = colorbar(ax);
cb.Label.String = 'Rank (1 = most important)';
for a = 1:nF
    for b = 1:size(rankShow, 2)
        if rankShow(a, b) <= nF / 2.4, tc = [1 1 1]; else, tc = [0.2 0.2 0.2]; end
        text(ax, b, a, sprintf('%d', rankShow(a, b)), 'HorizontalAlignment', 'center', ...
             'VerticalAlignment', 'middle', 'FontSize', 8, 'Color', tc, ...
             'FontName', 'Helvetica', 'Tag', 'keepColor');
    end
end
title(ax, 'F6.9  Predictor rank under each importance measure', ...
      'FontSize', 11, 'FontWeight', 'bold');
RPT.saveFig(fig, fullfile(figDir, 'F6_9_importance_rank_heatmap.png'));
close(fig);

%% F6.10 Out-of-bag permuted importance with fold-to-fold spread
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 720, 140 + 30 * nF]);
ax  = axes('Parent', fig); hold(ax, 'on');
vals = flipud(F.RF_OOBImportance_mean);
sds  = flipud(F.RF_OOBImportance_sd);
barh(ax, vals, 0.68, 'FaceColor', [0.00 0.45 0.70], 'FaceAlpha', 0.85, 'EdgeColor', 'none');
errorbar(ax, vals, (1:nF)', sds, 'horizontal', 'LineStyle', 'none', ...
         'Color', 'k', 'LineWidth', 0.8, 'CapSize', 3);
set(ax, 'YTick', 1:nF, 'YTickLabel', flipud(F.Feature), 'TickLabelInterpreter', 'none');
ylim(ax, [0.4 nF + 0.6]);
xlabel(ax, 'Out-of-bag permuted importance, mean over folds');
title(ax, 'F6.10  Random forest importance, ordered by mean rank across four measures', ...
      'FontSize', 11, 'FontWeight', 'bold');
RPT.styleAxes(ax);
RPT.saveFig(fig, fullfile(figDir, 'F6_10_rf_importance.png'));
close(fig);

%% Key results
topN = min(5, height(F));
RPT.logSection(keyFile, 'D6.6  Feature importance', [""; ...
    sprintf('Predictors ranked        : %d, over %d folds with a refit in each', nF, K); ...
    sprintf('Top five by mean rank    : %s', strjoin(F.Feature(1:topN)', ', ')); ...
    sprintf('Of those, hard to manipulate: %d', ...
            sum(ismember(F.Feature(1:topN), lowMan.Feature))); ...
    sprintf('Highest single-feature AUC : %.4f (%s)', ...
            max(F.SingleFeatureAUC), F.Feature{find(F.SingleFeatureAUC == max(F.SingleFeatureAUC), 1)})]);
RPT.logTable(keyFile, Timp, 14);
