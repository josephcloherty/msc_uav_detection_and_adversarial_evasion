%% Test Logistic Regression
%  Run train_logistic_regression.m first, then this script.
%  This script does not clear the workspace, so test_all.m can collect its results.

%% Locate the Phase 6 folder and load the model, its scaling and the test data
clc;
root = fileparts(which('prepare_data'));
assert(~isempty(root), 'test_logistic_regression:pathNotSet', ...
    'Run test_all.m, or set the current folder to Phase 6 before running this script.');
load(fullfile(root, 'models', 'model_logistic_regression.mat'), 'model', 'mu', 'sigma');
load(fullfile(root, 'prepared_data', 'phase6_data.mat'), 'Xtest', 'Ytest');
modelName = 'Logistic Regression';
posClass  = 'Aerial';                       % the UE class the detector must flag

%% Apply the training standardisation to the test predictors
%  The same mu and sigma from training are reused, so no test statistics leak in.
Ztest = (Xtest{:, :} - mu) ./ sigma;

%% Predict labels and class scores on the test set
%  fitclinear returns the raw linear score rather than a posterior, which is a
%  monotone function of the probability and so gives an identical ROC.
[pred, score] = predict(model, Ztest);
posCol = (model.ClassNames == posClass);    % score column for the Aerial class

%% Confusion counts at the default decision threshold
isPos   = (Ytest == posClass);
predPos = (pred  == posClass);
TP = sum(predPos &  isPos);
FP = sum(predPos & ~isPos);
TN = sum(~predPos & ~isPos);
FN = sum(~predPos &  isPos);

%% Headline metrics
accuracy  = (TP + TN) / numel(Ytest);
precision = TP / (TP + FP);
recall    = TP / (TP + FN);                 % true positive rate
fpr       = FP / (FP + TN);                 % false alarm rate on terrestrial UEs

%% ROC, AUC and detection rate at low false alarm rates
%  Accuracy flatters a 26 per cent positive class, so AUC is the headline number.
%  An operator cannot act on a detector that flags many terrestrial UEs, so the recall
%  still available at a 1 and 5 per cent false alarm rate is read off the test ROC.
[rocFPR, rocTPR, ~, auc] = perfcurve(Ytest, score(:, posCol), posClass);
tprAt1pct = rocTPR(find(rocFPR <= 0.01, 1, 'last'));
tprAt5pct = rocTPR(find(rocFPR <= 0.05, 1, 'last'));

%% Confusion matrix
figure;
confusionchart(Ytest, pred);
title([modelName ' - test set confusion matrix']);

%% Report
fprintf('\n=== %s test results ===\n', modelName);
fprintf('Accuracy        : %.3f\n', accuracy);
fprintf('Precision       : %.3f\n', precision);
fprintf('Recall (TPR)    : %.3f\n', recall);
fprintf('False pos. rate : %.3f\n', fpr);
fprintf('AUC-ROC         : %.3f\n', auc);
fprintf('Recall @ 1%% FPR : %.3f\n', tprAt1pct);
fprintf('Recall @ 5%% FPR : %.3f\n', tprAt5pct);
