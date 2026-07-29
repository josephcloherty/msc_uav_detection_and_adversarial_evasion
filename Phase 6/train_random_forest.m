%% Train Random Forest
%  Classification Learner equivalent: "Bagged Trees".
%  A random forest is bagged decision trees, each split choosing from a
%  random subset of predictors ('NumVariablesToSample' = 'sqrt').
%  Run prepare_data.m first, then this script.

%% Load the shared training data
clc;
load('phase6_data.mat', 'Xtrain', 'Ytrain');

%% Train the model
%  100 trees. Each tree is trained on a bootstrap sample and, at each split,
%  considers sqrt(numFeatures) randomly chosen predictors.
treeTemplate = templateTree('NumVariablesToSample', 'sqrt');
model = fitcensemble(Xtrain, Ytrain, ...
    'Method',            'Bag', ...
    'NumLearningCycles', 100, ...
    'Learners',          treeTemplate);

%% Save the trained model for test_random_forest.m
save('model_random_forest.mat', 'model');
fprintf('Trained random forest (100 trees) on %d samples. Saved to model_random_forest.mat\n', ...
        height(Xtrain));
