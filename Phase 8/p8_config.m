function C = p8_config()
%P8_CONFIG Every tunable in Phase 8, plus the integrity checks that must hold before it runs.
%   C = p8_config() returns a struct. Every Phase 8 script begins by calling it, so a
%   constant appears in exactly one place and the hold-out integrity assertions cannot be
%   skipped by running a stage on its own.
%
%   The checks here are not defensive padding. A hold-out result is only an estimate of
%   generalisation for as long as the hold-out has never influenced anything, and the
%   cheapest place to demonstrate that is a script that refuses to start otherwise.

root = fileparts(mfilename('fullpath'));
addpath(root);
addpath(fullfile(root, 'models'));          % frozen pipelines and the code that reads them

C = struct();
C.root       = root;
C.modelDir   = fullfile(root, 'models');
C.resultsDir = fullfile(root, 'results');
C.figureDir  = fullfile(root, 'figures');
C.phase7Dir  = fullfile(fileparts(root), 'Phase 7');
C.dataDir    = fullfile(C.phase7Dir, 'data');

for d = {C.resultsDir, C.figureDir}
    if ~isfolder(d{1}), mkdir(d{1}); end
end

%% Experimental design
C.holdoutSeeds = 46:60;
C.posClass     = 'Aerial';
C.posLabel     = 1;

%% Operating points
%  Index into pipeline.nominalFPR, which freeze_models wrote as [0.01 0.05]. The 1 per
%  cent point is the headline throughout; the 5 per cent point is a sensitivity check and
%  is carried through every table rather than being computed separately later.
C.opIdx    = 1;
C.opLabels = {'1pctFPR', '5pctFPR'};

%% Observation length
%  N_WIN truncates every UE-run to its first N windows before any comparison between
%  conditions. Leave empty to take the minimum window count observed across all
%  conditions, which is the only value at which every condition can be compared without
%  discarding a run.
%
%  This exists because the honest hold-out and the evasive conditions were not generated
%  at the same duration. A per-UE score is a mean posterior over a UE-run's windows, so
%  its sampling variance depends on how many there are, and if the aerial signature
%  varies along a trajectory then 30 windows samples a different part of the flight from
%  50. Comparing the two directly would report the difference in observation length as a
%  result of the evasion policy. If the final dataset generates every condition at the
%  same duration this becomes a no-op, which is the correct behaviour, not a reason to
%  remove it.
%
%  Truncation changes the null distribution of the per-UE statistic, so the false positive
%  rate achieved at the frozen threshold will drift from its nominal value under
%  truncation. That drift is a property of the observation length and not of any evasion
%  policy, which is why every evasive comparison is drawn against the truncated honest
%  baseline and never against the full-length one.
C.nWin = [];

%% Inference
C.nBoot    = 2000;
C.bootSeed = 8888;
C.ciLevel  = 0.95;

%% D8.5 base rate
%  Prevalence is the assumed fraction of connected UEs in a cell that are aerial. The
%  range spans four orders of magnitude because the honest answer is that nobody knows
%  it, and the shape of the PPV curve across that range is the argument.
C.prevalenceGrid    = logspace(-5, -2, 200);
C.prevalenceMarkers = [1e-4 1e-3 1e-2];
C.uesPerCellPerDay  = 5000;

%% D8.6 frontier
%  Three panels, one per mission profile, so the trade-off is not conditioned on a
%  profile choice that would have to be defended.
C.missionCostFile = fullfile(C.phase7Dir, 'results', ...
                             'phase7_missioncost_perseed_20260812_160237.csv');
C.costMetric      = 'C_op';
C.profiles        = {'reconnaissance', 'remotePiloting', 'terminalApproach'};

%% Output files
C.f = struct( ...
    'scoresWindow', fullfile(C.resultsDir, 'scores_window.csv'), ...
    'scoresUE',     fullfile(C.resultsDir, 'scores_ue.csv'), ...
    'provenance',   fullfile(C.resultsDir, 'provenance.csv'));

%% Discover the frozen pipelines
mf = dir(fullfile(C.modelDir, 'frozen_*.mat'));
assert(~isempty(mf), 'p8_config:noModels', ...
    ['No frozen_*.mat in %s. Run freeze_models.m in Phase 6, then copy the frozen ' ...
     'artefacts and their code dependencies into that folder.'], C.modelDir);
C.modelFiles = arrayfun(@(s) fullfile(s.folder, s.name), mf, 'UniformOutput', false);

C.modelNames = cell(numel(mf), 1);
C.modelKeys  = cell(numel(mf), 1);
primary = false(numel(mf), 1);
for k = 1:numel(mf)
    S = load(C.modelFiles{k}, 'pipeline');
    C.modelNames{k} = S.pipeline.name;
    C.modelKeys{k}  = S.pipeline.key;
    primary(k)      = S.pipeline.isPrimary;
end
assert(sum(primary) == 1, 'p8_config:primaryCount', ...
    'Expected exactly one frozen pipeline flagged as primary, found %d.', sum(primary));
C.primaryIdx   = find(primary);
C.primaryName  = C.modelNames{C.primaryIdx};

%% Discover the conditions
%  Honest first, then whatever evasive conditions exist on disk, with the combined
%  condition placed last. Nothing is hardcoded, so a third evasion action appearing in
%  the final dataset needs no change to any script.
assert(isfolder(fullfile(C.dataDir, 'honest')), 'p8_config:noHonest', ...
    'Cannot find %s', fullfile(C.dataDir, 'honest'));

ev = dir(fullfile(C.dataDir, 'evasive'));
ev = ev([ev.isdir] & ~startsWith({ev.name}, '.'));
evNames = sort({ev.name});
isComb  = strcmpi(evNames, 'combined');
C.individualConditions = evNames(~isComb);
C.combinedCondition    = evNames(isComb);
assert(numel(C.combinedCondition) <= 1, 'p8_config:manyCombined', ...
    'More than one folder looks like the combined condition.');

C.conditions = [{'honest'}, C.individualConditions, C.combinedCondition];
C.condPaths  = [{fullfile(C.dataDir, 'honest')}, ...
                cellfun(@(n) fullfile(C.dataDir, 'evasive', n), ...
                        [C.individualConditions, C.combinedCondition], 'UniformOutput', false)];

%% Integrity check: the hold-out must be disjoint from the development seeds
S = load(C.modelFiles{1}, 'pipeline');
devSeeds = S.pipeline.devSeeds;
overlap  = intersect(devSeeds, C.holdoutSeeds);
assert(isempty(overlap), 'p8_config:seedLeak', ...
    ['Seed(s) %s appear in both the development set the models were frozen on and the ' ...
     'declared hold-out. The hold-out result would not be an estimate of generalisation.'], ...
    mat2str(overlap));
C.devSeeds   = devSeeds;
C.freezeDate = S.pipeline.freezeDate;
C.frozenFeatureNames = S.pipeline.featureNames;

%% Integrity check: schema and window counts across the conditions
%  Reads one header per condition and one file per condition rather than the whole
%  dataset, so this stays cheap enough to run at the top of every stage.
minWin = Inf;
for c = 1:numel(C.conditions)
    files = dir(fullfile(C.condPaths{c}, 'features_*.csv'));
    assert(~isempty(files), 'p8_config:emptyCondition', ...
        'Condition "%s" has no features_*.csv in %s', C.conditions{c}, C.condPaths{c});

    seeds = nan(numel(files), 1);
    for k = 1:numel(files)
        tok = regexp(files(k).name, 'seed(\d+)\.csv$', 'tokens', 'once');
        assert(~isempty(tok), 'p8_config:unparsableName', ...
            'Cannot read a seed from the filename %s', files(k).name);
        seeds(k) = str2double(tok{1});
    end
    stray = setdiff(seeds, C.holdoutSeeds);
    assert(isempty(stray), 'p8_config:strayseed', ...
        ['Condition "%s" contains seed(s) %s outside the declared hold-out range. A ' ...
         'development seed in the test data would invalidate every Phase 8 number.'], ...
        C.conditions{c}, mat2str(stray'));

    T = readtable(fullfile(files(1).folder, files(1).name));
    missing = setdiff(C.frozenFeatureNames, T.Properties.VariableNames);
    assert(isempty(missing), 'p8_config:schemaDrift', ...
        ['Condition "%s" is missing predictor(s) the frozen pipelines require: %s. The ' ...
         'Phase 5 feature schema has changed since the freeze.'], ...
        C.conditions{c}, strjoin(missing, ', '));

    ue = strcat(string(T.scenario), '_', string(T.seed), '_', string(T.ueID));
    minWin = min(minWin, min(groupcounts(ue)));
end

if isempty(C.nWin)
    C.nWin = minWin;
end
assert(C.nWin <= minWin, 'p8_config:nWinTooLarge', ...
    ['C.nWin is %d but the shortest UE-run across the conditions has %d windows. ' ...
     'Lower C.nWin or regenerate the short condition at the longer duration.'], ...
    C.nWin, minWin);
C.minWinObserved = minWin;

end
