%% Phase 6 - Train every model
%  Run prepare_data.m first, then this script.
%  Reads:  prepared_data/phase6_data.mat
%  Writes: models/model_*.mat and models/importance_*.csv

%% Locate the Phase 6 folder and check the shared split exists
%  run() changes the current folder to the called script's own folder, so the root
%  goes on the MATLAB path here for the train scripts to find it again.
clear; clc;
root = fileparts(mfilename('fullpath'));
addpath(root);
dataFile = dir(fullfile(root, 'prepared_data', 'phase6_data.mat'));
assert(~isempty(dataFile), 'train_all:noData', ...
    'prepared_data/phase6_data.mat not found; run prepare_data.m first.');

% The saved split must postdate prepare_data.m, or its feature set is stale.
prepFile = dir(fullfile(root, 'prepare_data.m'));
assert(dataFile.datenum > prepFile.datenum, 'train_all:staleData', ...
    'prepared_data/phase6_data.mat is older than prepare_data.m; rerun prepare_data.m.');

if ~isfolder(fullfile(root, 'models')), mkdir(fullfile(root, 'models')); end

%% Call each training script in turn
%  Calling the scripts rather than redefining the models keeps one definition of each.
run(fullfile(root, 'train', 'train_knn.m'));
run(fullfile(root, 'train', 'train_random_forest.m'));
run(fullfile(root, 'train', 'train_decision_tree.m'));
run(fullfile(root, 'train', 'train_logistic_regression.m'));
run(fullfile(root, 'train', 'train_discriminant_analysis.m'));

%% Confirm every model file was written
root = fileparts(which('prepare_data'));   % the train scripts cleared the variable
expected = {'model_knn.mat', 'model_random_forest.mat', 'model_decision_tree.mat', ...
            'model_logistic_regression.mat', 'model_discriminant_analysis.mat'};
onDisk = cellfun(@(f) isfile(fullfile(root, 'models', f)), expected);
assert(all(onDisk), 'train_all:missingModel', ...
    'These model files were not written: %s', strjoin(expected(~onDisk), ', '));

fprintf('\nAll five models trained and saved to models/. Run test_all.m next.\n');
