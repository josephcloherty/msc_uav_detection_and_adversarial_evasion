%% Train Logistic Regression
%  Run prepare_data.m first, then this script.

%% Locate the Phase 6 folder and load the shared training data
clear; clc;
rng(42);
root = fileparts(which('prepare_data'));
assert(~isempty(root), 'train_logistic_regression:pathNotSet', ...
    'Run train_all.m, or set the current folder to Phase 6 before running this script.');
load(fullfile(root, 'prepared_data', 'phase6_data.mat'), 'Xtrain', 'Ytrain', 'featureNames');

%% Standardise the predictors
%  fitclinear applies a ridge penalty, which is not scale-invariant, and these
%  predictors span standard deviations from 0.03 to 3e5, so an unscaled penalty
%  would fall almost entirely on the small-scale features.
%  Only training statistics are used, and test_logistic_regression.m reapplies them.
mu    = mean(Xtrain{:, :}, 1);
sigma = std(Xtrain{:, :}, 0, 1);
sigma(sigma == 0) = 1;                     % guard: a zero-variance column
Ztrain = (Xtrain{:, :} - mu) ./ sigma;

%% Train the model
%  A 'logistic' learner fits a linear model of the log-odds of the Aerial class.
model = fitclinear(Ztrain, Ytrain, ...
    'Learner', 'logistic');

%% Coefficient magnitudes as a linear view of predictor importance
%  Coefficients are on the standardised scale, so their magnitudes are comparable.
[~, ord] = sort(abs(model.Beta), 'descend');
coefficients = table(featureNames(ord)', model.Beta(ord), ...
    'VariableNames', {'Feature', 'StdCoefficient'});
writetable(coefficients, fullfile(root, 'models', 'importance_logistic_regression.csv'));

%% Save the model and its scaling for test_logistic_regression.m
save(fullfile(root, 'models', 'model_logistic_regression.mat'), 'model', 'mu', 'sigma');
fprintf('Trained logistic regression on %d samples, %d predictors.\n', ...
        height(Xtrain), width(Xtrain));
fprintf('Largest coefficient: %s (%.3f). Saved models/model_logistic_regression.mat\n', ...
        coefficients.Feature{1}, coefficients.StdCoefficient(1));
