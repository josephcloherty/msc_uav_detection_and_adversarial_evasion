%% Train K-Nearest Neighbours (KNN)
%  Classification Learner equivalent: "Medium KNN".
%  Run prepare_data.m first, then this script.

%% Load the shared training data
clc;
load('phase6_data.mat', 'Xtrain', 'Ytrain');

%% Train the model
%  10 neighbours, Euclidean distance, standardised features (KNN is
%  distance-based, so predictors must be on a common scale).
model = fitcknn(Xtrain, Ytrain, ...
    'NumNeighbors', 10, ...
    'Distance',     'euclidean', ...
    'Standardize',  true);

%% Save the trained model for test_knn.m
save('model_knn.mat', 'model');
fprintf('Trained KNN on %d samples. Saved to model_knn.mat\n', height(Xtrain));
