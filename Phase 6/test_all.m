%% Phase 6 - Test every model and compare
%  Run train_all.m first, then this script.
%  Reads:  models/model_*.mat and prepared_data/phase6_data.mat
%  Writes: test_results.csv (one row per model)

%% Locate the Phase 6 folder and check the trained models exist
%  run() changes the current folder to the called script's own folder, so the root
%  goes on the MATLAB path here for the test scripts to find it again.
clear; clc; close all;
root = fileparts(mfilename('fullpath'));
addpath(root);
allTests = {'test_knn.m', 'test_random_forest.m', 'test_decision_tree.m', ...
            'test_logistic_regression.m', 'test_discriminant_analysis.m'};
allModels = {'model_knn.mat', 'model_random_forest.mat', 'model_decision_tree.mat', ...
             'model_logistic_regression.mat', 'model_discriminant_analysis.mat'};
onDisk = cellfun(@(f) isfile(fullfile(root, 'models', f)), allModels);
assert(all(onDisk), 'test_all:missingModel', ...
    'These model files are missing from models/: %s. Run train_all.m first.', ...
    strjoin(allModels(~onDisk), ', '));

%% Call each test script in turn and collect its metrics
%  The test scripts do not clear the workspace, so their results can be read back here.
%  Every model is scored on the same held-out runs, so the rows are directly comparable.
resultRows = cell(numel(allTests), 1);
for kTest = 1:numel(allTests)
    run(fullfile(root, 'test', allTests{kTest}));
    resultRows{kTest} = {modelName, accuracy, precision, recall, fpr, auc, tprAt1pct, tprAt5pct};
end

%% Build the comparison table, best AUC first
R = cell2table(vertcat(resultRows{:}), 'VariableNames', ...
    {'Model', 'Accuracy', 'Precision', 'Recall', 'FPR', 'AUC', ...
     'Recall_at_1pctFPR', 'Recall_at_5pctFPR'});
R = sortrows(R, 'AUC', 'descend');

%% Report
fprintf('\n===== Phase 6 model comparison (held-out runs, Aerial = positive) =====\n\n');
disp(R);

writetable(R, fullfile(root, 'test_results.csv'));
fprintf('Saved test_results.csv\n');
