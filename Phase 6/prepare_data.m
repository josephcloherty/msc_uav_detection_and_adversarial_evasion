%% Phase 6 - Prepare the development set (pool the runs, select features)
%  Reads:  data/features_*.csv
%  Writes: prepared_data/phase6_data.mat and prepared_data/leakage_check.csv
%
%  Phase 6 is fitted and evaluated entirely on development seeds 1 to 45. There is no
%  internal train/test split any more: cross-validation over these runs is the only
%  evidence used to select and freeze a classifier, and every hold-out run is left
%  untouched for Phase 7. Any seed outside the declared development range is refused
%  loading rather than merely excluded downstream, so no Phase 6 script can reach it.

%% Settings
clear; clc;
devSeeds = 1:45;                            % the development set, all of Phase 6
posClass = 'Aerial';

%% Feature switchboard
%  1 makes a predictor available to every model, 0 withholds it.
%  Every column of the Phase 5 schema that is not bookkeeping is listed here.

featureSwitch = {
    % --- serving cell SINR ---
    'servSINR_mean_dB'          1
    'servSINR_var_dB2'          0
    'servSINR_trend_perS'       0
    'servSINR_range_dB'         0
    'servSINR_iqr_dB'           0
    'servSINR_min_dB'           1
    'servSINR_max_dB'           0
    'servSINR_autocorr1'        0
    'servSINR_fadeRate_dBperS'  0

    % --- neighbour cell geometry ---
    'nbrSINR_max_mean_dB'       1
    'nbrSINR_mean_mean_dB'      1
    'nbrSINR_max_var_dB2'       1
    'sinrSpread_mean_dB'        1
    'sinrSpread_var_dB2'        0
    'sinrSpread_trend_perS'     0
    'numAboveThr_mean'          1
    'numAboveThr_var'           1
    'numAboveThr_max'           1
    'numAboveThr_trend_perS'    0
    'nbrWithin3dB_mean'         0
    'nbrWithin6dB_mean'         0
    'top3NbrSpread_mean_dB'     0
    'servMinusBestNbr_mean_dB'  0
    'servMinusBestNbr_min_dB'   0

    % --- channel quality and link adaptation ---
    'cqi_mean'                  1
    'cqi_var'                   0
    'cqi_trend_perS'            0
    'cqiSubbandSpread_mean'     0     % all-NaN in the current data so disabled
    'mcsDL_mean'                0
    'mcsDL_var'                 0
    'mcsUL_mean'                0
    'mcsUL_var'                 0
    'ulMcsCtx_mean'             0
    'ulMcsCtx_var'              0
    'spectralEff_bpsPerPRB'     0

    % --- MIMO rank ---
    'ri_mean'                   0
    'ri_var'                    0
    'rankOne_frac'              0
    'layers_mean'               0

    % --- retransmission: constant in the current data so disabled ---
    'retxRateDL'                0
    'retxRateUL'                0
    'retxRate'                  0

    % --- handover and mobility ---
    'hoCount_win'               1
    'meanInterHO_s'             0
    'hoRate_perS'               0     % identical to hoCount_win: the window is always
                                      % 10 s, so hoRate_perS * 10 == hoCount_win exactly
                                      % and the two correlate at 1.000000. Carrying both
                                      % splits the handover block's permutation
                                      % importance between two surrogates, because
                                      % permuting one leaves the other for the forest to
                                      % fall back on, and understates the block in D6.6.
    'pingPongCount_win'         1
    'timeSinceHO_mean_s'        0
    'timeSinceHO_min_s'         0
    'distinctServCells_win'     0
    'servCellEntropy'           0

    % --- timing advance: all-NaN in the current data so disabled ---
    'ta_mean'                   0
    'ta_var'                    0
    'ta_trend_perS'             0
    'ta_range'                  0

    % --- traffic volume: OFF, encodes the Phase 5 application model so disabled ---
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
%  Window position correlates with where in a flight the UE was and is meaningless on
%  an unseen run, and scenario is a run-level constant a model could memorise.
%  winStart_s is kept aside rather than discarded, because ordering a UE's windows in
%  time is what the persistence rule and the latency curve are built on.
bookkeeping = {'scenario', 'seed', 'ueID', 'label', 'winStart_s', 'winEnd_s'};

%% Resolve the folder layout and create the output folders if needed
root        = fileparts(mfilename('fullpath'));
preparedDir = fullfile(root, 'prepared_data');
if ~isfolder(preparedDir),                 mkdir(preparedDir);                 end
if ~isfolder(fullfile(root, 'models')),    mkdir(fullfile(root, 'models'));    end
if ~isfolder(fullfile(root, 'results')),   mkdir(fullfile(root, 'results'));   end
U = phase6_util();

%% Pool the development run CSVs into one table
%  Files are filtered by seed before being read, so a hold-out run sitting in data/
%  never enters the workspace at all.
files = dir(fullfile(root, 'data', 'features_*.csv'));
assert(~isempty(files), 'prepare_data:noData', ...
    'No features_*.csv found in %s', fullfile(root, 'data'));

fileSeed = nan(numel(files), 1);
for k = 1:numel(files)
    tok = regexp(files(k).name, 'seed(\d+)\.csv$', 'tokens', 'once');
    assert(~isempty(tok), 'prepare_data:unparsableName', ...
        'Cannot read a seed from the filename %s', files(k).name);
    fileSeed(k) = str2double(tok{1});
end
isDevFile = ismember(fileSeed, devSeeds);
excluded  = sort(fileSeed(~isDevFile))';
if ~isempty(excluded)
    fprintf('Not loaded, outside the development range: seed(s) %s\n', mat2str(excluded));
end
absent = setdiff(devSeeds, fileSeed');
if ~isempty(absent)
    fprintf('Note: %d development seed(s) have no CSV on disk: %s\n', ...
        numel(absent), mat2str(absent));
end
assert(any(isDevFile), 'prepare_data:noDevData', ...
    'None of the CSVs in data/ fall in the declared development seed range.');

data = table();
devFiles = files(isDevFile);
for k = 1:numel(devFiles)
    data = [data; readtable(fullfile(devFiles(k).folder, devFiles(k).name))]; %#ok<AGROW>
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

%% Build the response and the grouping keys
%  runKey identifies one simulation run and is the unit the folds are grouped on.
%  ueKey identifies one UE within one run and is the unit the decision rule acts on.
Ydev      = categorical(data.label, [0 1], {'Terrestrial', 'Aerial'});
runKeyDev = strcat(string(data.scenario), '_', string(data.seed));
ueKeyDev  = strcat(runKeyDev, '_', string(data.ueID));
seedDev   = double(data.seed);
scenDev   = string(data.scenario);
winStartDev = double(data.winStart_s);

assert(all(ismember(seedDev, devSeeds)), 'prepare_data:strayseed', ...
    'A row carries a seed outside the development range despite the file filter.');

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
    height(X), numel(unique(runKeyDev)), numel(featureNames));

%% Apply the feature switchboard
%  The list must stay in step with the Phase 5 schema, so a predictor that survives
%  the drops without a switch is an error rather than a silent omission.
switchNames = featureSwitch(:, 1);
switchOn    = cell2mat(featureSwitch(:, 2)) == 1;
assert(numel(unique(switchNames)) == numel(switchNames), 'prepare_data:duplicateFeature', ...
    'featureSwitch lists at least one feature twice.');
unlisted = setdiff(featureNames, switchNames);
assert(isempty(unlisted), 'prepare_data:unlistedFeature', ...
    'These predictors have no switch: %s. Add them to featureSwitch with a 0 or a 1.', ...
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

%% Collinearity tripwire on the selected predictors
%  A pair of predictors that are the same quantity in different units survives every
%  other check in this script: neither is empty, neither is constant, and neither is a
%  leak. It does damage further downstream instead. Permutation importance splits
%  between perfect surrogates, because permuting one leaves the other for the model to
%  fall back on, so a duplicated feature block is reported as two unimportant features
%  rather than one important one. hoRate_perS and hoCount_win were exactly this: the
%  window is always 10 s, so one is ten times the other.
Xsel = X{:, :};
Csel = corrcoef(U.imputeWith(Xsel, median(Xsel, 1, 'omitnan')), 'Rows', 'pairwise');
Csel(logical(eye(size(Csel)))) = 0;
[iDup, jDup] = find(triu(abs(Csel) >= 0.999, 1));
if ~isempty(iDup)
    msg = arrayfun(@(a, b) sprintf('%s and %s (r = %.6f)', ...
        featureNames{a}, featureNames{b}, Csel(a, b)), iDup, jDup, 'UniformOutput', false);
    error('prepare_data:duplicatePredictor', ...
        ['These selected predictors are the same quantity: %s. Switch one of each pair ' ...
         'off in featureSwitch; carrying both distorts the D6.6 importance ranking.'], ...
        strjoin(msg, '; '));
end
[iHi, jHi] = find(triu(abs(Csel) >= 0.95, 1));
for k = 1:numel(iHi)
    fprintf('Note: %s and %s correlate at %.3f; importance will be shared between them.\n', ...
        featureNames{iHi(k)}, featureNames{jHi(k)}, Csel(iHi(k), jHi(k)));
end

%% Hand the predictors on as a numeric matrix
%  Every downstream script standardises, imputes or permutes columns, all of which are
%  matrix operations, and the column order is carried by featureNames.
Xdev = X{:, :};
assert(numel(unique(Ydev)) == 2, 'prepare_data:singleClass', ...
    'The development set contains only one class.');

%% Leakage tripwire: single-feature separability
%  A predictor that alone reaches AUC 1.000 is not a signal, it is the label written in
%  another column, so it is reported here before any model is fitted. The audit uses a
%  median-imputed copy only; the saved matrix keeps its NaNs, because every fold has to
%  impute from its own training portion.
medAll = median(Xdev, 1, 'omitnan');
medAll(isnan(medAll)) = 0;
Xaudit = U.imputeWith(Xdev, medAll);

sepAUC = zeros(numel(featureNames), 1);
for j = 1:numel(featureNames)
    [~, ~, ~, a] = perfcurve(Ydev, Xaudit(:, j), posClass);
    sepAUC(j) = max(a, 1 - a);             % direction does not matter for separability
end
[sepSorted, ord] = sort(sepAUC, 'descend');
leakageCheck = table(featureNames(ord)', sepSorted, ...
    'VariableNames', {'Feature', 'SingleFeatureAUC'});
writetable(leakageCheck, fullfile(preparedDir, 'leakage_check.csv'));

%% Save for every downstream script to reuse
save(fullfile(preparedDir, 'phase6_data.mat'), ...
    'Xdev', 'Ydev', 'runKeyDev', 'ueKeyDev', 'seedDev', 'scenDev', 'winStartDev', ...
    'featureNames', 'featureSwitch', 'devSeeds', 'posClass');

%% Report the development set
runs = unique(runKeyDev);
fprintf('\n===== Phase 6 development set =====\n');
fprintf('Development seeds declared : %s\n', U.rangeText(devSeeds));
fprintf('Runs loaded                : %d\n', numel(runs));

fprintf('\n%-10s %-6s %-8s %-8s %-10s %s\n', ...
    'Scenario', 'Runs', 'Rows', 'UEs', 'AerialUEs', 'Seeds used');
for s = unique(scenDev)'
    pick = (scenDev == s);
    ueHere = unique(ueKeyDev(pick));
    nAer = sum(arrayfun(@(u) any(Ydev(ueKeyDev == u) == posClass), ueHere));
    used = unique(seedDev(pick))';
    fprintf('%-10s %-6d %-8d %-8d %-10d %s\n', ...
        s, numel(unique(runKeyDev(pick))), sum(pick), numel(ueHere), nAer, mat2str(used));
end

ueAll  = unique(ueKeyDev);
ueIsAer = arrayfun(@(u) any(Ydev(ueKeyDev == u) == posClass), ueAll);
fprintf('\nWindows : %d, aerial %.1f%%\n', numel(Ydev), 100 * mean(Ydev == posClass));
fprintf('UEs     : %d, aerial %d (%.1f%%), terrestrial %d\n', ...
    numel(ueAll), sum(ueIsAer), 100 * mean(ueIsAer), sum(~ueIsAer));

% The per-UE false alarm rate can only move in steps of one terrestrial UE, so the
% granularity is stated here rather than being discovered when a threshold is quoted.
nNegUE = sum(~ueIsAer);
fprintf('Per-UE FPR granularity : 1/%d = %.3f%%. A nominal 1%% target admits %d false alarms.\n', ...
    nNegUE, 100 / nNegUE, floor(0.01 * nNegUE));

%% Report which features are in play
fprintf('\nFeatures: %d in use, %d switched off, %d listed.\n', ...
    numel(featureNames), sum(~switchOn), numel(switchNames));
if any(~switchOn)
    fprintf('Switched off: %s\n', strjoin(switchNames(~switchOn), ', '));
end
fprintf('Saved prepared_data/phase6_data.mat\n');

%% Warn if any selected predictor is a near-perfect separator
%  With the traffic block switched off this should stay silent, so anything flagged is
%  either that block switched back on or a new confound needing investigation.
flagged = leakageCheck(leakageCheck.SingleFeatureAUC >= 0.99, :);
if ~isempty(flagged)
    fprintf('\nWARNING: %d predictor(s) separate the classes almost perfectly:\n', height(flagged));
    for j = 1:height(flagged)
        fprintf('  %-24s AUC %.4f\n', flagged.Feature{j}, flagged.SingleFeatureAUC(j));
    end
end
