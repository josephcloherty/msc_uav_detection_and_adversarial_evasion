%% Train Decision Tree
%  Run prepare_data.m first, then this script.

%% Locate the Phase 6 folder and load the shared training data
clear; clc;
rng(42);
root = fileparts(which('prepare_data'));
assert(~isempty(root), 'train_decision_tree:pathNotSet', ...
    'Run train_all.m, or set the current folder to Phase 6 before running this script.');
load(fullfile(root, 'prepared_data', 'phase6_data.mat'), 'Xtrain', 'Ytrain');

%% Train the model
%  MaxNumSplits caps the tree at 100 splits and MinLeafSize stops leaves being built
%  from a handful of near-duplicate overlapping windows.
model = fitctree(Xtrain, Ytrain, ...
    'MaxNumSplits', 100, ...
    'MinLeafSize',  20);

%% Save the trained model for test_decision_tree.m
save(fullfile(root, 'models', 'model_decision_tree.mat'), 'model');
fprintf('Trained decision tree (%d splits) on %d samples, %d predictors. Saved models/model_decision_tree.mat\n', ...
        sum(model.IsBranchNode), height(Xtrain), width(Xtrain));

%% Optional: view the tree
% view(model, 'Mode', 'graph');
