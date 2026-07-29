%% Train Decision Tree
%  Classification Learner equivalent: "Fine Tree".
%  Run prepare_data.m first, then this script.

%% Load the shared training data
clc;
load('phase6_data.mat', 'Xtrain', 'Ytrain');

%% Train the model
%  A single classification tree. MaxNumSplits caps tree size; 100 matches
%  the "Fine Tree" preset. Lower it (e.g. 20) for a simpler, more readable tree.
model = fitctree(Xtrain, Ytrain, ...
    'MaxNumSplits', 100);

%% Save the trained model for test_decision_tree.m
save('model_decision_tree.mat', 'model');
fprintf('Trained decision tree on %d samples. Saved to model_decision_tree.mat\n', ...
        height(Xtrain));

%% Optional: view the tree
% view(model, 'Mode', 'graph');
