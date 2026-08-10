%% Train K-Nearest Neighbours
%  Run prepare_data.m first, then this script.

%% Locate the Phase 6 folder and load the shared training data
clear; clc;
rng(42);
root = fileparts(which('prepare_data'));
assert(~isempty(root), 'train_knn:pathNotSet', ...
    'Run train_all.m, or set the current folder to Phase 6 before running this script.');
load(fullfile(root, 'prepared_data', 'phase6_data.mat'), 'Xtrain', 'Ytrain');

%% Train the model
%  KNN is distance-based, so 'Standardize' puts every predictor on a common scale
%  using training means and standard deviations only.
%  With k = 10 the class score takes only 11 distinct values, which makes the ROC coarse.
model = fitcknn(Xtrain, Ytrain, ...
    'NumNeighbors', 10, ...
    'Distance',     'euclidean', ...
    'Standardize',  true);

%% Save the trained model for test_knn.m
save(fullfile(root, 'models', 'model_knn.mat'), 'model');
fprintf('Trained KNN on %d samples, %d predictors. Saved models/model_knn.mat\n', ...
        height(Xtrain), width(Xtrain));
