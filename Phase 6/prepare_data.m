%% Phase 6 - Prepare data (pool the runs, select features, split by seed)
%  Run this ONCE before any train_*/test_* script.
%  Reads:  data/features_*.csv
%  Writes: prepared_data/phase6_data.mat and prepared_data/leakage_check.csv

%% Settings
%  The split is declared by run seed, not drawn at random, so the same runs land on
%  the same side every time and the ranges can be quoted directly in the write-up.
%  Phase 5 cycles the scenarios one per run, so a contiguous seed range is already
%  balanced across UMa, RMa and UMi; the report below confirms it for the actual data.
clear; clc;
trainSeeds = 1:29;                          % runs used to fit the models
testSeeds  = 30:36;                         % runs held out for testing
posClass   = 'Aerial';

%% Feature switchboard
%  1 makes a predictor available to every model, 0 withholds it.
%  Every column of the Phase 5 schema that is not bookkeeping is listed here.
%  A feature that is empty or constant in the current data is dropped whatever its
%  switch says, and the script reports which ones those were.
%
%  THE TRAFFIC BLOCK IS OFF BY DEFAULT AND SHOULD STAY OFF.
%  Phase 5 gave aerial UEs an uplink-heavy always-on application model and
%  terrestrial UEs a bursty downlink-heavy one, so every volume, throughput,
%  grant-rate and PRB-occupancy column records the configured traffic profile
%  rather than a radio consequence of being airborne. Four of them separate the
%  classes with no overlap at all between the two value ranges, and a model using
%  them reaches AUC 1.000 by reading the simulation setup back out of the features.
%  The whole block is off rather than only the columns that happen to separate, so
%  the decision rests on how the features were generated and not on a measured
%  score. Switch it on only as a deliberate leakage ablation, or once Phase 5 is
%  regenerated with a common traffic model for both UE types.
featureSwitch = {
    % --- serving cell SINR ---
    'servSINR_mean_dB'          1
    'servSINR_var_dB2'          1
    'servSINR_trend_perS'       1
    'servSINR_range_dB'         1
    'servSINR_iqr_dB'           1
    'servSINR_min_dB'           1
    'servSINR_max_dB'           1
    'servSINR_autocorr1'        1
    'servSINR_fadeRate_dBperS'  1

    % --- neighbour cell geometry ---
    'nbrSINR_max_mean_dB'       1
    'nbrSINR_mean_mean_dB'      1
    'nbrSINR_max_var_dB2'       1
    'sinrSpread_mean_dB'        1
    'sinrSpread_var_dB2'        1
    'sinrSpread_trend_perS'     1
    'numAboveThr_mean'          1
    'numAboveThr_var'           1
    'numAboveThr_max'           1
    'numAboveThr_trend_perS'    1
    'nbrWithin3dB_mean'         1
    'nbrWithin6dB_mean'         1
    'top3NbrSpread_mean_dB'     1
    'servMinusBestNbr_mean_dB'  1
    'servMinusBestNbr_min_dB'   1

    % --- channel quality and link adaptation ---
    'cqi_mean'                  1
    'cqi_var'                   1
    'cqi_trend_perS'            1
    'cqiSubbandSpread_mean'     1     % all-NaN in the current data
    'mcsDL_mean'                1
    'mcsDL_var'                 1
    'mcsUL_mean'                1
    'mcsUL_var'                 1
    'ulMcsCtx_mean'             1
    'ulMcsCtx_var'              1
    'spectralEff_bpsPerPRB'     1

    % --- MIMO rank ---
    'ri_mean'                   1
    'ri_var'                    1
    'rankOne_frac'              1
    'layers_mean'               1

    % --- retransmission ---
    'retxRateDL'                1     % constant in the current data
    'retxRateUL'                1     % constant in the current data
    'retxRate'                  1     % constant in the current data

    % --- handover and mobility ---
    'hoCount_win'               1
    'meanInterHO_s'             1
    'hoRate_perS'               1
    'pingPongCount_win'         1
    'timeSinceHO_mean_s'        1
    'timeSinceHO_min_s'         1
    'distinctServCells_win'     1
    'servCellEntropy'           1

    % --- timing advance ---
    'ta_mean'                   1     % all-NaN in the current data
    'ta_var'                    1     % all-NaN in the current data
    'ta_trend_perS'             1     % all-NaN in the current data
    'ta_range'                  1     % all-NaN in the current data

    % --- traffic volume: OFF, encodes the Phase 5 application model (see above) ---
    'ulVol_bytes'               0
    'dlVol_bytes'               0
    'ulVol_trend_Bps'           0
    'dlVol_trend_Bps'           0
    'ulThr_bps'                 0
    'dlThr_bps'                 0
    'thr_mean_bps'              0
    'grantRateUL_perS'          0
    'grantRateDL_perS'          0
    'prbUL_mean'                0
    'prbDL_mean'                0
    'prbUL_sum'                 0
    'prbDL_sum'                 0
    'dlulAsym'                  0
    'trafficBurstiness_cv'      0
    'trafficIdle_frac'          0
};

%% Bookkeeping columns
%  Never predictors: identifiers, the response, and where the window sits in the run.
%  Window position correlates with where in a flight the UE was and is meaningless
%  on an unseen run, and scenario is a run-level constant a model could memorise.
bookkeeping = {'scenario', 'seed', 'ueID', 'label', 'winStart_s', 'winEnd_s'};

%% Resolve the folder layout and create the output folders if needed
root        = fileparts(mfilename('fullpath'));
preparedDir = fullfile(root, 'prepared_data');
if ~isfolder(preparedDir),               mkdir(preparedDir);               end
if ~isfolder(fullfile(root, 'models')),  mkdir(fullfile(root, 'models'));  end

%% Pool every run CSV into one table
files = dir(fullfile(root, 'data', 'features_*.csv'));
assert(~isempty(files), 'prepare_data:noData', ...
    'No features_*.csv found in %s', fullfile(root, 'data'));
data = table();
for k = 1:numel(files)
    data = [data; readtable(fullfile(files(k).folder, files(k).name))]; %#ok<AGROW>
end

%% Guard: refuse to train on anything a network operator cannot measure
%  LOS state, altitude and true position are not observable and are near-collinear
%  with the aerial label, so they must never reach the Phase 5 feature schema.
allNames = data.Properties.VariableNames;
banned = allNames(~cellfun('isempty', regexpi(allNames, ...
    '(^|_)(is)?n?los($|_)|altitude|ueheight|pos[xyz]|truespeed')));
assert(isempty(banned), 'prepare_data:nonObservableColumn', ...
    ['The feature CSV contains column(s) a network operator cannot observe: %s. ' ...
     'Remove them from the Phase 5 schema.'], strjoin(banned, ', '));

%% Build the response and the run key
Y      = categorical(data.label, [0 1], {'Terrestrial', 'Aerial'});
runKey = strcat(string(data.scenario), '_', string(data.seed));
seedOfRow = double(data.seed);
scenOfRow = string(data.scenario);

%% Drop the bookkeeping columns
featureNames = setdiff(allNames, bookkeeping, 'stable');
X = data(:, featureNames);

%% Drop columns with no usable values at all
%  A feature the installed MATLAB release cannot supply arrives as an all-NaN column;
%  imputing it would leave a dead predictor in every model and distort the rankings.
dead = varfun(@(c) all(isnan(c)), X, 'OutputFormat', 'uniform');
if any(dead)
    fprintf('Dropping %d all-NaN column(s): %s\n', sum(dead), strjoin(featureNames(dead), ', '));
    featureNames = featureNames(~dead);
    X = X(:, featureNames);
end

%% Drop zero-variance columns
%  No information, and they make the covariance matrix singular for discriminant analysis.
constant = varfun(@(c) numel(unique(c(~isnan(c)))) <= 1, X, 'OutputFormat', 'uniform');
if any(constant)
    fprintf('Dropping %d constant column(s): %s\n', sum(constant), strjoin(featureNames(constant), ', '));
    featureNames = featureNames(~constant);
    X = X(:, featureNames);
end

fprintf('Pooled %d rows from %d runs, %d predictors before the switchboard.\n', ...
    height(X), numel(unique(runKey)), numel(featureNames));

%% Apply the feature switchboard
%  The list must stay in step with the Phase 5 schema, so a predictor that survives
%  the drops without a switch is an error rather than a silent omission.
switchNames = featureSwitch(:, 1);
switchOn    = cell2mat(featureSwitch(:, 2)) == 1;
assert(numel(unique(switchNames)) == numel(switchNames), 'prepare_data:duplicateFeature', ...
    'featureSwitch lists at least one feature twice.');
unlisted = setdiff(featureNames, switchNames);
assert(isempty(unlisted), 'prepare_data:unlistedFeature', ...
    ['These predictors have no switch: %s. Add them to featureSwitch with a 0 or a 1.'], ...
    strjoin(unlisted, ', '));

droppedAnyway = intersect(switchNames(switchOn), setdiff(switchNames, featureNames));
if ~isempty(droppedAnyway)
    fprintf('Note: %d switched-on feature(s) were empty or constant and dropped: %s\n', ...
        numel(droppedAnyway), strjoin(droppedAnyway, ', '));
end

selected     = ismember(featureNames, switchNames(switchOn));
X            = X(:, selected);
featureNames = featureNames(selected);
assert(~isempty(featureNames), 'prepare_data:noFeatures', ...
    'Every feature is switched off in featureSwitch.');

%% Check the declared seed ranges against what is actually on disk
assert(isempty(intersect(trainSeeds, testSeeds)), 'prepare_data:overlappingSeeds', ...
    'trainSeeds and testSeeds share seed(s): %s', mat2str(intersect(trainSeeds, testSeeds)));

seedsOnDisk = unique(seedOfRow)';
absentTrain = setdiff(trainSeeds, seedsOnDisk);
absentTest  = setdiff(testSeeds,  seedsOnDisk);
unassigned  = setdiff(seedsOnDisk, [trainSeeds, testSeeds]);
if ~isempty(absentTrain)
    fprintf('Note: trainSeeds lists %d seed(s) with no CSV on disk: %s\n', ...
        numel(absentTrain), mat2str(absentTrain));
end
if ~isempty(absentTest)
    fprintf('Note: testSeeds lists %d seed(s) with no CSV on disk: %s\n', ...
        numel(absentTest), mat2str(absentTest));
end
if ~isempty(unassigned)
    fprintf('Note: %d seed(s) on disk are in neither range and are DROPPED: %s\n', ...
        numel(unassigned), mat2str(unassigned));
end

%% Split whole runs by seed
%  A run's windows never straddle the split, because the 1 s stride on a 10 s window
%  makes neighbouring rows about 90 per cent identical.
isTrainRow = ismember(seedOfRow, trainSeeds);
isTestRow  = ismember(seedOfRow, testSeeds);

Xtrain = X(isTrainRow, :);  Ytrain = Y(isTrainRow);
Xtest  = X(isTestRow,  :);  Ytest  = Y(isTestRow);

%% Impute missing values with TRAIN medians only
%  meanInterHO_s is NaN whenever a window holds fewer than two handovers, which
%  hoCount_win already records, so the imputed value adds no new information.
med = median(Xtrain{:, :}, 1, 'omitnan');
med(isnan(med)) = 0;                       % guard: column all-NaN in train -> 0
Xtrain = imputeWith(Xtrain, med);
Xtest  = imputeWith(Xtest,  med);

%% Guards
assert(~any(isnan(Xtrain{:, :}), 'all') && ~any(isnan(Xtest{:, :}), 'all'), ...
    'prepare_data:residualNaN', 'NaNs survived imputation.');
assert(numel(unique(Ytrain)) == 2 && numel(unique(Ytest)) == 2, ...
    'prepare_data:singleClass', 'A split contains only one class; adjust the seed ranges.');

%% Leakage tripwire: single-feature separability on the training set
%  A predictor that alone reaches AUC 1.000 is not a signal, it is the label written
%  in another column, so it is reported here before any model is fitted.
sepAUC = zeros(numel(featureNames), 1);
for j = 1:numel(featureNames)
    [~, ~, ~, a] = perfcurve(Ytrain, Xtrain{:, j}, posClass);
    sepAUC(j) = max(a, 1 - a);             % direction does not matter for separability
end
[sepSorted, ord] = sort(sepAUC, 'descend');
leakageCheck = table(featureNames(ord)', sepSorted, ...
    'VariableNames', {'Feature', 'SingleFeatureAUC'});
writetable(leakageCheck, fullfile(preparedDir, 'leakage_check.csv'));

%% Save for every downstream script to reuse
%  Xall is feature-selected but NOT imputed, because run_cv.m imputes per fold.
%  featureSwitch is saved so a set of results can be traced to the features behind it.
Xall = X;  Yall = Y;  runKeyAll = runKey;
save(fullfile(preparedDir, 'phase6_data.mat'), ...
    'Xtrain', 'Ytrain', 'Xtest', 'Ytest', 'featureNames', 'featureSwitch', ...
    'Xall', 'Yall', 'runKeyAll');

%% Report which seeds went where
fprintf('\n===== Phase 6 split =====\n');
fprintf('Train seeds declared : %s\n', rangeText(trainSeeds));
fprintf('Test  seeds declared : %s\n', rangeText(testSeeds));

fprintf('\n%-10s %-6s %-6s %-8s %s\n', 'Scenario', 'Side', 'Runs', 'Rows', 'Seeds used');
for s = ["UMa", "RMa", "UMi"]
    for side = ["Train", "Test"]
        if side == "Train", rowMask = isTrainRow; else, rowMask = isTestRow; end
        pick = rowMask & (scenOfRow == s);
        if ~any(pick), continue; end
        used = unique(seedOfRow(pick))';
        fprintf('%-10s %-6s %-6d %-8d %s\n', s, side, numel(used), sum(pick), mat2str(used));
    end
end

fprintf('\nTrain: %d rows from %d runs, aerial %.1f%%\n', ...
    height(Xtrain), numel(unique(seedOfRow(isTrainRow))), 100 * mean(Ytrain == posClass));
fprintf('Test : %d rows from %d runs, aerial %.1f%%\n', ...
    height(Xtest),  numel(unique(seedOfRow(isTestRow))),  100 * mean(Ytest  == posClass));

%% Report which features are in play
fprintf('\nFeatures: %d in use, %d switched off, %d listed.\n', ...
    numel(featureNames), sum(~switchOn), numel(switchNames));
if any(~switchOn)
    fprintf('Switched off: %s\n', strjoin(switchNames(~switchOn), ', '));
end
fprintf('Saved prepared_data/phase6_data.mat\n');

%% Warn if any selected predictor is a near-perfect separator
%  With the traffic block switched off this should stay silent, so anything flagged
%  is either that block switched back on or a new confound needing investigation.
flagged = leakageCheck(leakageCheck.SingleFeatureAUC >= 0.99, :);
if ~isempty(flagged)
    fprintf('\nWARNING: %d predictor(s) separate the classes almost perfectly:\n', height(flagged));
    for j = 1:height(flagged)
        fprintf('  %-24s AUC %.4f\n', flagged.Feature{j}, flagged.SingleFeatureAUC(j));
    end
end

%% ---- local helper: replace NaNs with supplied column medians ----
function T = imputeWith(T, colMedians)
    A = T{:, :};
    for j = 1:size(A, 2)
        A(isnan(A(:, j)), j) = colMedians(j);
    end
    T{:, :} = A;
end

%% ---- local helper: print a seed list as a range when it is contiguous ----
function s = rangeText(v)
    if numel(v) > 1 && isequal(v, min(v):max(v))
        s = sprintf('%d:%d (%d seeds)', min(v), max(v), numel(v));
    else
        s = sprintf('%s (%d seeds)', mat2str(v), numel(v));
    end
end
