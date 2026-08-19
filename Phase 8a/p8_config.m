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
C.dataDir    = fullfile(root, 'data');

for d = {C.resultsDir, C.figureDir}
    if ~isfolder(d{1}), mkdir(d{1}); end
end

%% Phase 8 reads only its own copy of the data
%  Everything Phase 8 touches is a copy held inside Phase 8, for the same reason the
%  frozen pipelines are copied here: a hold-out evaluation that reaches into a live
%  working directory is one edit away from no longer being a hold-out evaluation.
%
%  It also lets the hold-out assertion below stay an outright refusal rather than a
%  filter. Phase 7 generates the honest condition across all sixty seeds because it
%  shares a generator with Phase 5, so reading it directly would mean Phase 8 depended
%  on a seed filter for its central guarantee. Copying only seeds 46 to 60 into this
%  folder makes the guarantee physical: there is no development data here to leak.
assert(isfolder(C.dataDir), 'p8_config:noData', ...
    ['%s does not exist. Copy the hold-out data into it before running Phase 8:\n' ...
     '  data/honest/                 seeds 46-60 only, from Phase 7/data/honest\n' ...
     '  data/evasive/<condition>/    each condition folder from Phase 7/data/evasive\n' ...
     '  data/<mission cost csv>      the per-seed output of phase7_MissionCost\n' ...
     'Do not copy the development seeds; the hold-out check below will refuse them.'], ...
    C.dataDir);

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
%  Named explicitly rather than found by pattern, because more than one timestamped run
%  may sit in the folder and the frontier must be traceable to a stated cost table.
C.missionCostFile = fullfile(C.dataDir, ...
                             'phase7_missioncost_perseed_20260819_134743.csv');
assert(isfile(C.missionCostFile), 'p8_config:noMissionCost', ...
    ['Mission cost table not found at %s. Copy the per-seed output of ' ...
     'phase7_MissionCost into Phase 8/data/, or update C.missionCostFile.'], ...
    C.missionCostFile);
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

%  The evasion conditions are peers. There is no "combined" condition in the sense of a
%  superposition to be decomposed, because the two folders differ by which actions the
%  evader takes and not by whether one is the sum of others:
%
%    lowAltitude       the aerial UE descends to 15 m
%    lowAltLowSpeed    it descends to 15 m and also flies at terrestrial speeds
%
%  An earlier version treated the second as lowAltitude + trafficReshaping and tested
%  whether the two compounded. That test was not computable as posed: the folder also
%  applies a speed reduction that neither individual condition contains, so the residual
%  was the main effect of a third action rather than an interaction. Naming the condition
%  for what the evader actually does removes the trap.
%
%  trafficReshaping is not analysed. It alters only the traffic and scheduling columns,
%  and the Phase 6 leakage audit switched that whole block off because it encoded the
%  Phase 5 application model rather than any radio consequence of being airborne. On the
%  twelve frozen predictors it is inert by construction: matched aerial windows differ
%  from honest by a median of 0.0000 dB in serving SINR. It belongs in the write-up as a
%  stated null result, not as a column in every table.
C.condLabelMap = { ...
    'honest',         'honest'
    'lowAltitude',    'low altitude'
    'lowAltLowSpeed', 'low altitude + low speed' };

ev = dir(fullfile(C.dataDir, 'evasive'));
ev = ev([ev.isdir] & ~startsWith({ev.name}, '.'));
evNames = sort({ev.name});

known = C.condLabelMap(:, 1);
unknown = setdiff(evNames, known);
assert(isempty(unknown), 'p8_config:unknownCondition', ...
    ['Condition folder(s) %s have no entry in C.condLabelMap. Add a display label, or ' ...
     'remove the folder if the condition is not being analysed.'], strjoin(unknown, ', '));

C.conditions = [{'honest'}, evNames];
C.condPaths  = [{fullfile(C.dataDir, 'honest')}, ...
                cellfun(@(n) fullfile(C.dataDir, 'evasive', n), evNames, ...
                        'UniformOutput', false)];
C.evasiveConditions = evNames;

% Display labels, resolved once so no stage invents its own wording.
C.condLabels = cell(size(C.conditions));
for c = 1:numel(C.conditions)
    C.condLabels{c} = C.condLabelMap{strcmp(known, C.conditions{c}), 2};
end
C.labelOf = @(name) C.condLabelMap{strcmp(C.condLabelMap(:, 1), name), 2};

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
%
%  The hold-out filter is applied here and nowhere else. Phase 7 generates the honest
%  condition across all sixty seeds because it shares a generator with Phase 5, so the
%  copied data folder contains development runs that must never reach a Phase 8 number.
%  Rather than let each stage glob its own directory and hope every one of them filters
%  identically, this loop resolves the file list once and publishes it as C.condFiles.
%  Every stage reads that list. A stage that globs the folder itself is a bug.
%
%  The two failure modes are treated differently on purpose. A development seed present
%  on disk is expected and is silently excluded, with a count reported. A declared
%  hold-out seed that is absent is fatal, because a hold-out quietly evaluated on twelve
%  runs instead of fifteen is a worse problem than one that refuses to start.
minWin = Inf;
C.condFiles = cell(size(C.conditions));
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

    keep  = ismember(seeds, C.holdoutSeeds);
    stray = sort(seeds(~keep))';
    files = files(keep);
    seeds = seeds(keep);

    missing = setdiff(C.holdoutSeeds, seeds');
    assert(isempty(missing), 'p8_config:missingHoldoutSeed', ...
        ['Condition "%s" is missing hold-out seed(s) %s. Every declared hold-out seed ' ...
         'must be present, or the conditions are not evaluated on the same runs.'], ...
        C.conditions{c}, mat2str(missing));
    assert(numel(unique(seeds)) == numel(seeds), 'p8_config:duplicateSeed', ...
        'Condition "%s" has more than one file for the same seed.', C.conditions{c});

    if ~isempty(stray)
        fprintf(['Condition "%s": excluded %d file(s) outside the hold-out range ' ...
                 '(seeds %d to %d); %d hold-out runs retained.\n'], ...
            C.conditions{c}, numel(stray), min(stray), max(stray), numel(files));
    end
    C.condFiles{c} = arrayfun(@(f) fullfile(f.folder, f.name), files, ...
                              'UniformOutput', false);

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
