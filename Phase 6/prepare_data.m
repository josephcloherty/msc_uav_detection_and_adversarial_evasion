%% Phase 6 - Prepare data (grouped train/test split)
%  Pools every Phase 5 run CSV and holds out WHOLE runs (scenario+seed) for
%  testing, so windows from one UE never land in both train and test.
%  Windows use a 1 s stride on a 10 s window, so neighbouring rows overlap
%  by about 90 per cent; a random row split would leak that overlap and
%  overstate performance. Run this ONCE before any train_*/test_* script.
%
%  Requires: Statistics and Machine Learning Toolbox, phase6_LoadDataset.m.
%  Output:   phase6_data.mat (Xtrain, Ytrain, Xtest, Ytest, featureNames)

%% Settings
clear; clc;
rng(42);                                  % fixed seed for a reproducible split
dataDir  = fullfile('..', 'Phase 5', 'data');   % where features_*.csv live
testFrac = 0.30;                                % share of runs per scenario held out

%% Load and pool every run
[X, Y, runKey, featureNames] = phase6_LoadDataset(dataDir);

%% Grouped, scenario-stratified hold-out (whole runs go to one side)
%  Each run (scenario+seed) is one group. Holding out whole runs keeps every
%  window of a UE together. Selecting a fraction of runs within EACH scenario
%  keeps UMa, RMa and UMi present in both train and test.
runs       = unique(runKey);
scenPerRun = extractBefore(runs, '_');
isTestRun  = false(size(runs));
for s = unique(scenPerRun)'
    idx   = find(scenPerRun == s);
    nTest = max(1, round(testFrac * numel(idx)));
    isTestRun(idx(randperm(numel(idx), nTest))) = true;
end
isTestRow = ismember(runKey, runs(isTestRun));

Xtrain = X(~isTestRow, :);  Ytrain = Y(~isTestRow);
Xtest  = X(isTestRow, :);   Ytest  = Y(isTestRow);

%% Impute missing values with TRAIN medians only (no leakage)
%  meanInterHO_s is NaN when a window has no handover; hoCount_win already
%  encodes that (it is 0), so median imputation loses no information and lets
%  the distance- and covariance-based models (KNN, logistic, LDA) run.
med    = median(Xtrain{:, :}, 1, 'omitnan');
med(isnan(med)) = 0;                       % guard: column all-NaN in train -> 0
Xtrain = imputeWith(Xtrain, med);
Xtest  = imputeWith(Xtest,  med);

%% Save the split for every model to reuse
save('phase6_data.mat', 'Xtrain', 'Ytrain', 'Xtest', 'Ytest', 'featureNames');

fprintf('Train: %d rows from %d runs | Test: %d rows from %d runs.\n', ...
    height(Xtrain), sum(~isTestRun), height(Xtest), sum(isTestRun));
fprintf('Aerial share  train %.1f%%   test %.1f%%\n', ...
    100 * mean(Ytrain == 'Aerial'), 100 * mean(Ytest == 'Aerial'));

%% ---- local helper: replace NaNs with supplied column medians ----
function T = imputeWith(T, colMedians)
    A = T{:, :};
    for j = 1:size(A, 2)
        A(isnan(A(:, j)), j) = colMedians(j);
    end
    T{:, :} = A;
end
