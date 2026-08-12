%% Phase 6 D6.7 - Select the primary classifier, refit on all 45 runs and freeze
%  Reads:  prepared_data/phase6_data.mat, results/cv_results.csv,
%          prepared_data/ue_rule.mat, prepared_data/thresholds.mat
%  Writes: models/frozen_<key>.mat, one per family
%          results/freeze_manifest.csv
%
%  Selection uses cross-validation evidence and nothing else. That is the whole point of
%  the exercise: once a hold-out run has influenced which model is chosen, the hold-out
%  result stops being an estimate of generalisation and becomes another development
%  number. The criterion is recorded in the manifest so the choice can be audited rather
%  than taken on trust.
%
%  All five families are refitted on the full 45 development runs and frozen, not just
%  the primary one, because the exit criterion asks for five frozen pipelines and because
%  a secondary family is worth having when the primary one behaves unexpectedly on
%  hold-out data.
%
%  A frozen pipeline carries its own preprocessing, decision rule and thresholds. Nothing
%  downstream is permitted to recompute an imputation median, a scaling constant or a
%  threshold, since every one of those fitted on hold-out data would leak.

%% Settings
clear; clc;
rng(9999);
root = fileparts(mfilename('fullpath'));
addpath(root);
U = phase6_util();
freezeDate = datetime('now', 'TimeZone', 'local');
freezeDate.Format = 'yyyy-MM-dd HH:mm:ss';

load(fullfile(root, 'prepared_data', 'phase6_data.mat'), ...
     'Xdev', 'Ydev', 'runKeyDev', 'featureNames', 'featureSwitch', 'devSeeds', 'posClass');
load(fullfile(root, 'prepared_data', 'ue_rule.mat'), 'chosen', 'modelNames', 'modelKeys');
load(fullfile(root, 'prepared_data', 'thresholds.mat'), 'winThr', 'ueThr', 'nominalFPR');
cv = readtable(fullfile(root, 'results', 'cv_results.csv'));
ueSel = readtable(fullfile(root, 'results', 'ue_rule_chosen.csv'));

nM = numel(modelNames);
assert(height(cv) == nM && height(ueSel) == nM, 'freeze_models:tableMismatch', ...
    'The cross-validation tables do not cover the same five families; rerun the pipeline.');

%% Select the primary classifier
%  Ordered on the per-UE partial AUC below a 5 per cent false alarm rate, computed on the
%  pooled out-of-fold scores under each family's own decision rule.
%
%  Recall at the 1 per cent operating point was the criterion originally specified and is
%  the quantity the detector is ultimately for, but it cannot carry the selection. With
%  three hundred and sixty terrestrial UEs a nominal 1 per cent target admits three false
%  alarms and no other number, so recall can only separate two families in whole UEs out
%  of the hundred and nineteen aerial ones; on the first clean execution the two leading
%  families were separated by exactly one. Worse, when the same figure is taken fold by
%  fold the achieved rate varies between families, so a family that overshot the target
%  was being rewarded for the overshoot. The partial AUC is free of both problems: it
%  needs no threshold, and it integrates the whole region an operator could work in
%  rather than one discrete point within it.
%
%  Recall at 1 per cent remains in the manifest and is the figure to quote for the
%  chosen model. It is reported, not used to choose.
[~, cvLoc] = ismember(modelNames, cv.Model);
[~, ueLoc] = ismember(modelNames, ueSel.Model);
assert(all(cvLoc > 0) && all(ueLoc > 0), 'freeze_models:nameMismatch', ...
    'A model name in ue_rule.mat has no matching row in the results tables.');
assert(ismember('Pooled_PerUE_pAUC5norm', ueSel.Properties.VariableNames), ...
    'freeze_models:staleRuleTable', ...
    ['results/ue_rule_chosen.csv predates the pooled selection criterion; ' ...
     'rerun per_ue_rule.m before freezing.']);

primaryCriterion = ueSel.Pooled_PerUE_pAUC5norm(ueLoc);
reportedRecall   = ueSel.Pooled_Recall_at_1pctFPR(ueLoc);
achievedFPR      = ueSel.Pooled_AchievedFPR(ueLoc);
tieBreak         = cv.pAUC5norm_mean(cvLoc);
[~, primaryIdx]  = max(primaryCriterion + 1e-6 * tieBreak);

fprintf('Selection on cross-validation evidence alone.\n');
fprintf('Criterion: pooled per-UE partial AUC below 5%% FPR. Recall is reported, not used.\n\n');
fprintf('%-22s %18s %14s %13s %14s\n', ...
    'Model', 'pAUC<5%FPR (crit)', 'Recall@1%FPR', 'AchievedFPR', 'Window pAUC');
for m = 1:nM
    mark = ' ';
    if m == primaryIdx, mark = '*'; end
    fprintf('%s%-21s %18.4f %14.4f %12.3f%% %14.4f\n', mark, modelNames{m}, ...
        primaryCriterion(m), reportedRecall(m), 100 * achievedFPR(m), tieBreak(m));
end

% A criterion that cannot separate the top two is not doing its job, and the write-up
% should say so rather than presenting a coin toss as a finding.
sorted = sort(primaryCriterion, 'descend');
if numel(sorted) > 1 && (sorted(1) - sorted(2)) < 0.01
    warning('freeze_models:narrowSelection', ...
        ['The top two families are separated by %.4f on the selection criterion, which is ' ...
         'narrow enough that the choice should be reported as a near-tie rather than as a ' ...
         'clear result.'], sorted(1) - sorted(2));
end
fprintf('\nPrimary classifier: %s\n\n', modelNames{primaryIdx});

%% Fit the preprocessing on the full development set
%  These are the constants the frozen pipelines carry. They are computed once, here, from
%  all 45 runs, and are never recomputed on any later data.
med = median(Xdev, 1, 'omitnan');
med(isnan(med)) = 0;
Xfit = U.imputeWith(Xdev, med);
mu    = mean(Xfit, 1);
sigma = std(Xfit, 0, 1);
sigma(sigma == 0) = 1;
Zfit = (Xfit - mu) ./ sigma;

%% Refit and freeze each family
M = phase6_models(numel(featureNames));
assert(isequal({M.key}', modelKeys), 'freeze_models:registryDrift', ...
    'The model registry no longer matches the families the cross-validation used.');

manifest = cell(nM, 1);
for m = 1:nM
    if M(m).needsZ
        model = M(m).fit(Zfit, Ydev);
    else
        model = M(m).fit(Xfit, Ydev);
    end

    pipeline = struct();
    pipeline.name         = M(m).name;
    pipeline.key          = M(m).key;
    pipeline.model        = model;
    pipeline.scoreFcn     = M(m).score;
    pipeline.needsZ       = M(m).needsZ;
    pipeline.featureNames = featureNames;
    pipeline.imputeMedian = med;
    pipeline.mu           = mu;
    pipeline.sigma        = sigma;
    pipeline.rule         = chosen(m);
    pipeline.ruleLabel    = U.ruleLabel(chosen(m));
    pipeline.nominalFPR   = nominalFPR;
    pipeline.windowThreshold = winThr(m, :);   % ordered as nominalFPR
    pipeline.ueThreshold     = ueThr(m, :);
    pipeline.posClass     = posClass;
    pipeline.devSeeds     = devSeeds;
    pipeline.nDevRuns     = numel(unique(runKeyDev));
    pipeline.nDevRows     = size(Xdev, 1);
    pipeline.featureSwitch = featureSwitch;
    pipeline.isPrimary    = (m == primaryIdx);
    pipeline.selectionCriterion = 'pooled per-UE partial AUC below 5% FPR';
    pipeline.selectionValue     = primaryCriterion(m);
    pipeline.reportedRecall     = reportedRecall(m);
    pipeline.reportedFPR        = achievedFPR(m);
    pipeline.freezeDate   = freezeDate;
    pipeline.matlabVersion = version;

    outFile = fullfile(root, 'models', sprintf('frozen_%s.mat', M(m).key));
    save(outFile, 'pipeline');

    manifest{m} = {M(m).name, M(m).key, pipeline.isPrimary, U.ruleLabel(chosen(m)), ...
        winThr(m, 1), winThr(m, 2), ueThr(m, 1), ueThr(m, 2), ...
        primaryCriterion(m), reportedRecall(m), achievedFPR(m), tieBreak(m), ...
        numel(featureNames), pipeline.nDevRuns, pipeline.nDevRows, string(freezeDate)};

    fprintf('Froze %-22s -> models/frozen_%s.mat\n', M(m).name, M(m).key);
end

Man = cell2table(vertcat(manifest{:}), 'VariableNames', ...
    {'Model', 'Key', 'IsPrimary', 'DecisionRule', ...
     'WindowThreshold_1pct', 'WindowThreshold_5pct', ...
     'UEThreshold_1pct', 'UEThreshold_5pct', ...
     'SelectionCriterion_PerUE_pAUC5norm', 'Reported_PerUE_Recall_at_1pctFPR', ...
     'Reported_PerUE_AchievedFPR', 'CV_Window_pAUC5norm', 'nFeatures', ...
     'nDevRuns', 'nDevRows', 'FreezeDate'});
writetable(Man, fullfile(root, 'results', 'freeze_manifest.csv'));

fprintf('\nFreeze date: %s\n', string(freezeDate));
fprintf('Five pipelines frozen on %d development runs, %d rows, %d predictors.\n', ...
    numel(unique(runKeyDev)), size(Xdev, 1), numel(featureNames));
fprintf('Saved results/freeze_manifest.csv\n');
fprintf(['\nPhase 6 exit: each frozen file produces a window score, a per-UE score and a\n' ...
         'decision at a threshold fixed without reference to any hold-out data.\n' ...
         'Apply one with score_pipeline.m. Nothing further should be refitted in Phase 7.\n']);
