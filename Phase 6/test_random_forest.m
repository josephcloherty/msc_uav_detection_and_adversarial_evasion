%% Test Random Forest
%  Evaluates the trained random forest on the held-out test set.
%  Aerial is the positive class (the UE class we want to detect).
%  Run train_random_forest.m first, then this script.

%% Load the trained model and the shared test data
clc;
load('model_random_forest.mat', 'model');
load('phase6_data.mat', 'Xtest', 'Ytest');
posClass = 'Aerial';

%% Predict labels and class scores on the test set
[pred, score] = predict(model, Xtest);

%% Confusion matrix
figure;
confusionchart(Ytest, pred);
title('Random Forest - test set confusion matrix');

%% Confusion counts (Aerial = positive)
isPos   = (Ytest == posClass);          % true aerial
predPos = (pred  == posClass);          % predicted aerial
TP = sum(predPos &  isPos);
FP = sum(predPos & ~isPos);
TN = sum(~predPos & ~isPos);
FN = sum(~predPos &  isPos);

%% Headline metrics
accuracy  = (TP + TN) / numel(Ytest);
precision = TP / (TP + FP);
recall    = TP / (TP + FN);             % true positive rate
fpr       = FP / (FP + TN);             % false alarm rate on terrestrial UEs

%% AUC-ROC (primary metric; low FPR is the binding operational constraint)
posCol = (model.ClassNames == posClass);            % score column for Aerial
[~, ~, ~, auc] = perfcurve(Ytest, score(:, posCol), posClass);

%% Report
fprintf('\n=== Random Forest test results ===\n');
fprintf('Accuracy        : %.3f\n', accuracy);
fprintf('Precision       : %.3f\n', precision);
fprintf('Recall (TPR)    : %.3f\n', recall);
fprintf('False pos. rate : %.3f\n', fpr);
fprintf('AUC-ROC         : %.3f\n', auc);
