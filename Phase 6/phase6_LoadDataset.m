function [X, Y, runKey, featureNames] = phase6_LoadDataset(dataDir)
%phase6_LoadDataset Pool every Phase 5 feature CSV into model-ready data.
%   [X, Y, runKey, featureNames] = phase6_LoadDataset(dataDir) reads every
%   features_*.csv in dataDir, concatenates them, and returns:
%     X            table of the operator-observable predictors
%     Y            categorical response, 0 -> Terrestrial, 1 -> Aerial
%     runKey       per-row "scenario_seed" string; the grouping key for a
%                  leakage-free split (all of a run's windows share a key)
%     featureNames predictor column names (the single source of truth)
%
%   Shared by prepare_data.m and run_cv.m so the schema lives in one place.
%
%   PREDICTOR SELECTION
%   -------------------
%   The predictor list is DERIVED from the CSV header by removing the
%   bookkeeping columns, rather than being written out by hand. Up to
%   Phase 5 it was a hard-coded list of 20 names, which meant any column
%   added upstream was silently ignored here: the schema could grow and
%   the models would keep training on the old subset without complaining.
%   Deriving it removes that failure mode, at the cost of needing the
%   exclusion list below to be right.
%
%   EXCLUDED, and why each one must stay excluded:
%     scenario    the propagation scenario. An operator does know its own
%                 deployment type, but it is a run-level CONSTANT here, so
%                 leaving it in lets a model memorise which scenarios
%                 happened to carry more aerial UEs in this dataset.
%     seed        run identifier, pure leakage
%     ueID        node identity, pure leakage
%     label       the response
%     winStart_s  window position within the run. Correlated with where in
%     winEnd_s    a flight the UE was, and meaningless on unseen runs.
%
%   There is deliberately NO LOS column in the Phase 5 schema to exclude.
%   LOS state is not observable by an operator and is near-collinear with
%   the aerial label, so it is written to the run diagnostics instead. The
%   guard below stops the load outright if a column matching a LOS flag or
%   a raw position/altitude quantity ever appears, rather than letting it
%   quietly inflate every score in this phase.
%
%   ALL-NaN and CONSTANT COLUMNS are dropped with a printed note. A
%   feature the installed MATLAB release cannot supply (timing advance is
%   the likely one) arrives as an all-NaN column; imputing it to a
%   constant would leave a dead predictor in every model and distort the
%   feature-importance rankings the write-up depends on.

    if nargin < 1 || isempty(dataDir)
        dataDir = fullfile('..', 'Phase 5', 'data');
    end

    files = dir(fullfile(dataDir, 'features_*.csv'));
    assert(~isempty(files), 'phase6_LoadDataset:noData', ...
        'No features_*.csv found in %s', dataDir);

    % Pool every run into one table
    data = table();
    for k = 1:numel(files)
        data = [data; readtable(fullfile(files(k).folder, files(k).name))]; %#ok<AGROW>
    end

    excluded = {'scenario', 'seed', 'ueID', 'label', ...
                'winStart_s', 'winEnd_s'};

    allNames = data.Properties.VariableNames;

    % Guard: refuse to train on anything a network operator cannot measure.
    banned = allNames(~cellfun('isempty', regexpi(allNames, ...
        '(^|_)(is)?n?los($|_)|altitude|ueheight|pos[xyz]|truespeed')));
    assert(isempty(banned), 'phase6_LoadDataset:nonObservableColumn', ...
        ['The feature CSV contains column(s) a network operator cannot ' ...
         'observe: %s. These would leak the label. Remove them from the ' ...
         'Phase 5 schema, or add them to the exclusion list here with a ' ...
         'written justification.'], strjoin(banned, ', '));

    featureNames = setdiff(allNames, excluded, 'stable');
    X = data(:, featureNames);

    % Drop columns with no usable values at all
    dead = varfun(@(c) all(isnan(c)), X, 'OutputFormat', 'uniform');
    if any(dead)
        fprintf(['phase6_LoadDataset: dropping %d all-NaN column(s): %s\n' ...
                 '  (the run logs never supplied these; run ' ...
                 'phase4SchedulerCheck if that is unexpected)\n'], ...
            sum(dead), strjoin(featureNames(dead), ', '));
        featureNames = featureNames(~dead);
        X = X(:, featureNames);
    end

    % Drop zero-variance columns: no information, and they make the
    % covariance matrix singular for discriminant analysis.
    constant = varfun(@(c) numel(unique(c(~isnan(c)))) <= 1, X, ...
        'OutputFormat', 'uniform');
    if any(constant)
        fprintf('phase6_LoadDataset: dropping %d constant column(s): %s\n', ...
            sum(constant), strjoin(featureNames(constant), ', '));
        featureNames = featureNames(~constant);
        X = X(:, featureNames);
    end

    Y      = categorical(data.label, [0 1], {'Terrestrial', 'Aerial'});
    runKey = strcat(string(data.scenario), '_', string(data.seed));

    fprintf('phase6_LoadDataset: %d rows, %d predictors, %d runs.\n', ...
        height(X), numel(featureNames), numel(unique(runKey)));
end
