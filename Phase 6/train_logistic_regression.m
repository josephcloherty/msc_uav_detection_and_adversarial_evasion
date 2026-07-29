%% Train Logistic Regression
%  Classification Learner equivalent: "Logistic Regression".
%  fitclinear with a logistic learner fits a linear log-odds model and is
%  the recommended baseline for this project.
%  Run prepare_data.m first, then this script.

%% Load the shared training data
clc;
load('phase6_data.mat', 'Xtrain', 'Ytrain');

%% Train the model
%  'logistic' learner => binary logistic regression.
model = fitclinear(Xtrain, Ytrain, ...
    'Learner', 'logistic');

%% Save the trained model for test_logistic_regression.m
save('model_logistic_regression.mat', 'model');
fprintf('Trained logistic regression on %d samples. Saved to model_logistic_regression.mat\n', ...
        height(Xtrain));
