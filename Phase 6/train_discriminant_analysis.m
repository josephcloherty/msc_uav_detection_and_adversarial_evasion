%% Train Discriminant Analysis
%  Classification Learner equivalent: "Linear Discriminant".
%  Run prepare_data.m first, then this script.

%% Load the shared training data
clc;
load('phase6_data.mat', 'Xtrain', 'Ytrain');

%% Train the model
%  'pseudoLinear' is linear discriminant analysis that uses a pseudo-inverse
%  of the covariance matrix, so it still runs when features are correlated
%  (SINR/CQI features here are). Use 'linear' for textbook LDA, or
%  'quadratic'/'pseudoQuadratic' for a curved decision boundary.
model = fitcdiscr(Xtrain, Ytrain, ...
    'DiscrimType', 'pseudoLinear');

%% Save the trained model for test_discriminant_analysis.m
save('model_discriminant_analysis.mat', 'model');
fprintf('Trained discriminant analysis on %d samples. Saved to model_discriminant_analysis.mat\n', ...
        height(Xtrain));
