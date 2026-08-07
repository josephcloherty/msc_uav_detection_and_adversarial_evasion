%% Train Discriminant Analysis
%  Run prepare_data.m first, then this script.

%% Locate the Phase 6 folder and load the shared training data
clear; clc;
rng(42);
root = fileparts(which('prepare_data'));
assert(~isempty(root), 'train_discriminant_analysis:pathNotSet', ...
    'Run train_all.m, or set the current folder to Phase 6 before running this script.');
load(fullfile(root, 'prepared_data', 'phase6_data.mat'), 'Xtrain', 'Ytrain');

%% Train the model
%  'pseudoLinear' is linear discriminant analysis using a pseudo-inverse of the
%  pooled covariance matrix, which stays defined when predictors are collinear.
%  The SINR, CQI and MCS features here are strongly correlated, so a plain inverse fails.
model = fitcdiscr(Xtrain, Ytrain, ...
    'DiscrimType', 'pseudoLinear');

%% Save the trained model for test_discriminant_analysis.m
save(fullfile(root, 'models', 'model_discriminant_analysis.mat'), 'model');
fprintf('Trained discriminant analysis on %d samples, %d predictors. Saved models/model_discriminant_analysis.mat\n', ...
        height(Xtrain), width(Xtrain));
