%% Train Random Forest
%  Run prepare_data.m first, then this script.

%% Locate the Phase 6 folder and load the shared training data
clear; clc;
rng(42);                                   % bagging is stochastic, so fix the seed
root = fileparts(which('prepare_data'));
assert(~isempty(root), 'train_random_forest:pathNotSet', ...
    'Run train_all.m, or set the current folder to Phase 6 before running this script.');
load(fullfile(root, 'prepared_data', 'phase6_data.mat'), 'Xtrain', 'Ytrain', 'featureNames');

%% Train the model
%  Each of the 100 trees sees a bootstrap sample and considers sqrt(numFeatures)
%  randomly chosen predictors at every split, which decorrelates the trees.
%  NumVariablesToSample needs an explicit integer, so sqrt is evaluated here.
numVars = max(1, round(sqrt(width(Xtrain))));
model = fitcensemble(Xtrain, Ytrain, ...
    'Method',            'Bag', ...
    'NumLearningCycles', 100, ...
    'Learners',          templateTree('NumVariablesToSample', numVars, 'Reproducible', true));

%% Predictor importance from out-of-bag permutation
%  Each predictor is shuffled in the out-of-bag rows and the rise in error recorded,
%  so the ranking is measured on rows that tree did not train on.
imp = oobPermutedPredictorImportance(model);
[~, ord] = sort(imp, 'descend');
importance = table(featureNames(ord)', imp(ord)', ...
    'VariableNames', {'Feature', 'OOBImportance'});
writetable(importance, fullfile(root, 'models', 'importance_random_forest.csv'));

%% Save the trained model for test_random_forest.m
save(fullfile(root, 'models', 'model_random_forest.mat'), 'model');
fprintf('Trained random forest (100 trees, %d vars/split) on %d samples, %d predictors.\n', ...
        numVars, height(Xtrain), width(Xtrain));
fprintf('Top predictor: %s (OOB importance %.3f). Saved models/model_random_forest.mat\n', ...
        importance.Feature{1}, importance.OOBImportance(1));
