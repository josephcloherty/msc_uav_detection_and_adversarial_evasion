%% Phase 6 D6.4 - Derive the operating thresholds from pooled out-of-fold scores
%  Reads:  prepared_data/oof_scores.mat and prepared_data/ue_rule.mat
%  Writes: prepared_data/thresholds.mat
%          results/thresholds.csv
%
%  The primary operating point is a 1 per cent false positive rate; 5 per cent is kept
%  as a sensitivity point rather than as an alternative headline. Both are derived at
%  window level and at per-UE level, because the two are different quantities: flagging
%  1 per cent of windows is not the same as flagging 1 per cent of subscribers, and the
%  per-UE rate is the one an operator would be held to.
%
%  Thresholds are read off the pooled out-of-fold scores, so every score used was
%  produced by a model that had not seen the run it came from, and no hold-out data is
%  involved at any point.
%
%  The achieved rate is recorded beside the nominal one throughout. A finite sample
%  cannot in general hit a nominal rate exactly, and at per-UE level the achieved rate
%  can only move in steps of one terrestrial UE, which is coarse enough that quoting the
%  nominal figure alone would misrepresent the result.

%% Settings
clear; clc;
root = fileparts(mfilename('fullpath'));
addpath(root);
U = phase6_util();

nominalFPR = [0.01 0.05];                   % primary first, sensitivity second

load(fullfile(root, 'prepared_data', 'oof_scores.mat'), ...
     'oofScore', 'modelNames', 'modelKeys', 'Ydev', 'ueKeyDev', 'winStartDev', 'posClass');
load(fullfile(root, 'prepared_data', 'ue_rule.mat'), 'chosen');

isPos = (Ydev == posClass);
nM    = numel(modelNames);

rowsOut = cell(0, 9);
winThr  = nan(nM, numel(nominalFPR));
ueThr   = nan(nM, numel(nominalFPR));
ueScoreAll = cell(nM, 1);

for m = 1:nM
    % --- window level ---
    for q = 1:numel(nominalFPR)
        [t, achFPR, rec, nFP, nNeg] = U.pickThreshold(oofScore(:, m), isPos, nominalFPR(q));
        winThr(m, q) = t;
        rowsOut(end+1, :) = {modelNames{m}, 'Window', 'window score', nominalFPR(q), ...
            t, achFPR, rec, nFP, nNeg}; %#ok<SAGROW>
    end

    % --- per-UE level, under the rule selected in D6.3 ---
    S = U.perUEScore(oofScore(:, m), ueKeyDev, winStartDev, isPos, chosen(m));
    ueScoreAll{m} = S;
    for q = 1:numel(nominalFPR)
        [t, achFPR, rec, nFP, nNeg] = U.pickThreshold(S.Score, S.IsPos, nominalFPR(q));
        ueThr(m, q) = t;
        rowsOut(end+1, :) = {modelNames{m}, 'PerUE', U.ruleLabel(chosen(m)), nominalFPR(q), ...
            t, achFPR, rec, nFP, nNeg}; %#ok<SAGROW>
    end
end

T = cell2table(rowsOut, 'VariableNames', ...
    {'Model', 'Level', 'DecisionRule', 'NominalFPR', 'Threshold', ...
     'AchievedFPR', 'Recall', 'FalsePositives', 'NegativeUnits'});
writetable(T, fullfile(root, 'results', 'thresholds.csv'));

%% Report
fprintf('Operating points from pooled out-of-fold scores.\n');
fprintf('Nominal is the target, achieved is what the sample actually delivers.\n\n');
fprintf('%-22s %-7s %-8s %10s %10s %10s %8s\n', ...
    'Model', 'Level', 'Nominal', 'Threshold', 'Achieved', 'Recall', 'FP/neg');
for i = 1:height(T)
    fprintf('%-22s %-7s %7.0f%% %10.4f %9.3f%% %10.3f %4d/%d\n', ...
        T.Model{i}, T.Level{i}, 100 * T.NominalFPR(i), T.Threshold(i), ...
        100 * T.AchievedFPR(i), T.Recall(i), T.FalsePositives(i), T.NegativeUnits(i));
end

%  Recall at the per-UE operating point moves in whole UEs, so ties are common and are
%  reported as ties. Naming whichever family happened to sort first would read as a
%  result and is exactly the claim this phase must not make by accident.
primary = T(T.NominalFPR == 0.01 & strcmp(T.Level, 'PerUE'), :);
best    = primary.Model(primary.Recall == max(primary.Recall));
if numel(best) == 1
    fprintf('\nPrimary operating point, 1%% per-UE FPR, best recall: %s at %.3f.\n', ...
        best{1}, max(primary.Recall));
else
    fprintf(['\nPrimary operating point, 1%% per-UE FPR: %d families tie on best recall at ' ...
             '%.3f (%s).\nRecall alone cannot separate them; D6.7 selects on the partial ' ...
             'AUC.\n'], numel(best), max(primary.Recall), strjoin(best', ', '));
end

save(fullfile(root, 'prepared_data', 'thresholds.mat'), ...
     'winThr', 'ueThr', 'nominalFPR', 'modelNames', 'modelKeys', 'ueScoreAll', 'T');

fprintf('\nSaved results/thresholds.csv and prepared_data/thresholds.mat\n');
fprintf('Run latency_curve.m next.\n');
