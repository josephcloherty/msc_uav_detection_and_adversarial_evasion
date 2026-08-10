%% Phase 6 - Grouped 5-fold cross-validation across all five models
%  Optional companion to train_all.m/test_all.m; reuses every run for both fitting
%  and validation, which matters when runs are expensive to generate.
%  Output: cv_results.csv (one row per model)

%% Settings
clear; clc;
rng(9999);
root     = fileparts(mfilename('fullpath'));
K        = 5;              % requested folds, auto-reduced if a scenario has fewer runs
posClass = 'Aerial';

%% Load the pooled dataset written by prepare_data.m
%  Xall carries the same feature switchboard selection as the train/test split, and
%  is deliberately not imputed because each fold imputes on its own training portion.
load(fullfile(root, 'prepared_data', 'phase6_data.mat'), 'Xall', 'Yall', 'runKeyAll');
X = Xall;  Y = Yall;  runKey = runKeyAll;
runs       = unique(runKey);
scenPerRun = extractBefore(runs, '_');

%% Assign whole runs to folds, round-robin within each scenario
%  Keeping a run's windows in one fold stops the 90 per cent overlap between
%  neighbouring windows leaking across the fold boundary.
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

%% Models, using the same presets as the individual train scripts
%  needsZ marks the model whose penalty is scale-dependent and so requires z-scored input.
names    = {'KNN', 'Random Forest', 'Decision Tree', 'Logistic Regression', 'Discriminant Analysis'};
needsZ   = [false, false, false, true, false];
numVars  = max(1, round(sqrt(width(X))));   % NumVariablesToSample needs an explicit integer
trainers = { ...
    @(Xtr,Ytr) fitcknn(Xtr, Ytr, 'NumNeighbors', 10, 'Distance', 'euclidean', 'Standardize', true), ...
    @(Xtr,Ytr) fitcensemble(Xtr, Ytr, 'Method', 'Bag', 'NumLearningCycles', 100, ...
                            'Learners', templateTree('NumVariablesToSample', numVars, 'Reproducible', true)), ...
    @(Xtr,Ytr) fitctree(Xtr, Ytr, 'MaxNumSplits', 100, 'MinLeafSize', 20), ...
    @(Xtr,Ytr) fitclinear(Xtr, Ytr, 'Learner', 'logistic'), ...
    @(Xtr,Ytr) fitcdiscr(Xtr, Ytr, 'DiscrimType', 'pseudoLinear') };

auc    = nan(numel(names), K);
acc    = nan(numel(names), K);
fpr    = nan(numel(names), K);
tpr01  = nan(numel(names), K);
tpr05  = nan(numel(names), K);

%% Cross-validate, fitting every preprocessing step on the training fold only
for f = 1:K
    tr = foldOfRow ~= f;   te = foldOfRow == f;
    Xtr = X(tr, :); Ytr = Y(tr);
    Xte = X(te, :); Yte = Y(te);

    med = median(Xtr{:, :}, 1, 'omitnan');        % training-fold medians only
    med(isnan(med)) = 0;                          % guard: all-NaN column -> 0
    Xtr = imputeWith(Xtr, med);
    Xte = imputeWith(Xte, med);

    mu    = mean(Xtr{:, :}, 1);                   % training-fold scaling only
    sigma = std(Xtr{:, :}, 0, 1);
    sigma(sigma == 0) = 1;
    Ztr = (Xtr{:, :} - mu) ./ sigma;
    Zte = (Xte{:, :} - mu) ./ sigma;

    for m = 1:numel(names)
        if needsZ(m)
            model = trainers{m}(Ztr, Ytr);
            [pred, score] = predict(model, Zte);
        else
            model = trainers{m}(Xtr, Ytr);
            [pred, score] = predict(model, Xte);
        end
        posCol = (model.ClassNames == posClass);

        [rocFPR, rocTPR, ~, auc(m, f)] = perfcurve(Yte, score(:, posCol), posClass);
        tpr01(m, f) = rocTPR(find(rocFPR <= 0.01, 1, 'last'));
        tpr05(m, f) = rocTPR(find(rocFPR <= 0.05, 1, 'last'));

        TP = sum(pred == posClass & Yte == posClass);
        FP = sum(pred == posClass & Yte ~= posClass);
        TN = sum(pred ~= posClass & Yte ~= posClass);
        acc(m, f) = (TP + TN) / numel(Yte);
        fpr(m, f) = FP / (FP + TN);
    end
end

%% Report
fprintf('\n%-22s %17s %10s %8s %10s %10s\n', ...
    'Model', 'AUC (mean+/-sd)', 'Accuracy', 'FPR', 'TPR@1%FPR', 'TPR@5%FPR');
for m = 1:numel(names)
    fprintf('%-22s   %5.3f +/- %5.3f   %6.3f   %6.3f     %6.3f     %6.3f\n', ...
        names{m}, mean(auc(m, :)), std(auc(m, :)), mean(acc(m, :)), ...
        mean(fpr(m, :)), mean(tpr01(m, :)), mean(tpr05(m, :)));
end

%% Save results for the chapter 4 write-up (D6.2)
R = table(names', mean(auc, 2), std(auc, 0, 2), mean(acc, 2), mean(fpr, 2), ...
    mean(tpr01, 2), mean(tpr05, 2), 'VariableNames', ...
    {'Model', 'AUC_mean', 'AUC_sd', 'Accuracy_mean', 'FPR_mean', ...
     'Recall_at_1pctFPR_mean', 'Recall_at_5pctFPR_mean'});
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
