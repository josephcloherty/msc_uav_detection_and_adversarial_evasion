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
exportgraphics(fig, fullfile(root, 'results', 'feature_importance.png'), 'Resolution', 200);
close(fig);

fprintf('\nSaved results/feature_importance.csv and results/feature_importance.png\n');
fprintf('Run freeze_models.m next.\n');
