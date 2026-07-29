%% Phase 6 - 5-fold grouped cross-validation across all five models
%  Pools every Phase 5 run, assigns WHOLE runs (scenario+seed) to folds so no
%  run's windows straddle a fold, then reports mean +/- sd AUC, accuracy and
%  false positive rate per model. Grouped CV reuses every expensive run for
%  both training and validation, which is the right choice when data is
%  costly to generate. Aerial is the positive class.
%
%  Requires: Statistics and Machine Learning Toolbox, phase6_LoadDataset.m.
%  Output:   cv_results.csv (one row per model)

%% Settings
clear; clc;
rng(42);
dataDir  = fullfile('..', 'Phase 5', 'data');
K        = 5;              % requested folds (auto-reduced if runs are few)
posClass = 'Aerial';

%% Load and pool every run
[X, Y, runKey] = phase6_LoadDataset(dataDir);
runs       = unique(runKey);
scenPerRun = extractBefore(runs, '_');

%% Assign whole runs to folds, round-robin within each scenario
%  so every fold contains UMa, RMa and UMi. K is capped at the smallest
%  scenario's run count so no fold can be empty.
K = min(K, min(histcounts(categorical(scenPerRun))));
foldOfRun = zeros(size(runs));
for s = unique(scenPerRun)'
    idx = find(scenPerRun == s);
    idx = idx(randperm(numel(idx)));            % shuffle within scenario
    foldOfRun(idx) = mod(0:numel(idx)-1, K) + 1;
end
[~, rIdx] = ismember(runKey, runs);
foldOfRow = foldOfRun(rIdx);
fprintf('Grouped %d-fold CV over %d runs (%d rows).\n', K, numel(runs), height(X));

%% Models (same presets as the individual train scripts)
names    = {'KNN', 'Random Forest', 'Decision Tree', 'Logistic Regression', 'Discriminant'};
trainers = { ...
    @(Xtr,Ytr) fitcknn(Xtr, Ytr, 'NumNeighbors', 10, 'Distance', 'euclidean', 'Standardize', true), ...
    @(Xtr,Ytr) fitcensemble(Xtr, Ytr, 'Method', 'Bag', 'NumLearningCycles', 100, ...
                            'Learners', templateTree('NumVariablesToSample', 'sqrt')), ...
    @(Xtr,Ytr) fitctree(Xtr, Ytr, 'MaxNumSplits', 100), ...
    @(Xtr,Ytr) fitclinear(Xtr, Ytr, 'Learner', 'logistic'), ...
    @(Xtr,Ytr) fitcdiscr(Xtr, Ytr, 'DiscrimType', 'pseudoLinear') };

auc = nan(numel(names), K);
acc = nan(numel(names), K);
fpr = nan(numel(names), K);

%% Cross-validate: impute per fold on the training portion only
for f = 1:K
    tr = foldOfRow ~= f;   te = foldOfRow == f;
    Xtr = X(tr, :); Ytr = Y(tr);
    Xte = X(te, :); Yte = Y(te);

    med = median(Xtr{:, :}, 1, 'omitnan');       % train-fold medians only
    med(isnan(med)) = 0;                          % guard: all-NaN column -> 0
    Xtr = imputeWith(Xtr, med);
    Xte = imputeWith(Xte, med);

    for m = 1:numel(names)
        model = trainers{m}(Xtr, Ytr);
        [pred, score] = predict(model, Xte);
        posCol = (model.ClassNames == posClass);
        [~, ~, ~, auc(m, f)] = perfcurve(Yte, score(:, posCol), posClass);
        TP = sum(pred == posClass & Yte == posClass);
        FP = sum(pred == posClass & Yte ~= posClass);
        TN = sum(pred ~= posClass & Yte ~= posClass);
        FN = sum(pred ~= posClass & Yte == posClass); %#ok<NASGU>
        acc(m, f) = (TP + TN) / numel(Yte);
        fpr(m, f) = FP / (FP + TN);
    end
end

%% Report
fprintf('\n%-22s %16s %11s %9s\n', 'Model', 'AUC (mean+/-sd)', 'Accuracy', 'FPR');
for m = 1:numel(names)
    fprintf('%-22s   %5.3f +/- %5.3f   %6.3f    %6.3f\n', ...
        names{m}, mean(auc(m, :)), std(auc(m, :)), mean(acc(m, :)), mean(fpr(m, :)));
end

%% Save results for the chapter 4 write-up (D6.2)
R = table(names', mean(auc, 2), std(auc, 0, 2), mean(acc, 2), mean(fpr, 2), ...
    'VariableNames', {'Model', 'AUC_mean', 'AUC_sd', 'Accuracy_mean', 'FPR_mean'});
writetable(R, 'cv_results.csv');
fprintf('\nSaved cv_results.csv\n');

%% ---- local helper: replace NaNs with supplied column medians ----
function T = imputeWith(T, colMedians)
    A = T{:, :};
    for j = 1:size(A, 2)
        A(isnan(A(:, j)), j) = colMedians(j);
    end
    T{:, :} = A;
end
