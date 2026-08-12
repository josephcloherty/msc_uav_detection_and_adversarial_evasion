%% Phase 6 D6.3 - Specify and fit the per-UE decision rule
%  Reads:  prepared_data/oof_scores.mat
%  Writes: prepared_data/ue_rule.mat
%          results/ue_rule_candidates.csv   every candidate rule, fold-wise
%          results/ue_rule_chosen.csv       the rule selected for each model
%
%  An operator decides about a subscriber, not about a ten-second window, so the window
%  scores have to be collapsed into one score per UE. Two families are compared:
%
%    mean posterior   the UE's score is the average posterior over its windows. Uses
%                     every window equally and is the natural choice if the aerial
%                     signature is persistent.
%    M-of-N           the UE is flagged when M of any N consecutive windows exceed the
%                     window threshold. Robust to a minority of misleading windows and
%                     is the form an operator would actually deploy, since it maps onto
%                     a counter rather than a running average.
%
%  Both are written as continuous per-UE scores so that each has an ROC and the two can
%  be compared on the same footing rather than at one arbitrary operating point. The
%  M-of-N score is the maximum, over all blocks of N consecutive windows, of the M-th
%  largest score in the block; thresholding it at t is exactly the persistence rule.
%
%  Selection uses the cross-validation folds and nothing else. For each fold the per-UE
%  threshold is derived on the other four folds and applied to the held-out one, so no
%  rule parameter is chosen using the same UEs it is then scored on.

%% Settings
clear; clc;
root = fileparts(mfilename('fullpath'));
addpath(root);
U = phase6_util();

targetFPR = 0.01;                            % the primary per-UE operating point
Ncand     = [3 5 7 10];                      % persistence window lengths to consider

load(fullfile(root, 'prepared_data', 'oof_scores.mat'), ...
     'oofScore', 'modelNames', 'modelKeys', 'Ydev', 'ueKeyDev', 'runKeyDev', ...
     'winStartDev', 'foldOfRow', 'K', 'posClass');

isPos = (Ydev == posClass);
nM    = numel(modelNames);

%% Build the candidate rule list
rules = struct('type', {}, 'M', {}, 'N', {});
rules(1).type = 'mean';  rules(1).M = NaN;  rules(1).N = NaN;
for N = Ncand
    for Mv = 1:N
        rules(end+1).type = 'mofn';  rules(end).M = Mv;  rules(end).N = N; %#ok<SAGROW>
    end
end
nR = numel(rules);

%% Map each UE to its fold
%  A UE belongs to exactly one run and a run to exactly one fold, so the UE-level
%  partition is inherited from the window-level one without any further grouping.
[ueList, ia] = unique(ueKeyDev, 'stable');
ueFold = foldOfRow(ia);
nUEneg = sum(arrayfun(@(u) ~any(isPos(ueKeyDev == u)), ueList));
fprintf('%d UEs across %d folds. Per-UE FPR moves in steps of 1/%d = %.3f%%.\n', ...
    numel(ueList), K, nUEneg, 100 / nUEneg);
fprintf('A nominal %.0f%% target therefore admits %d false alarms.\n\n', ...
    100 * targetFPR, floor(targetFPR * nUEneg));

%% Evaluate every candidate rule for every model, fold by fold
rowsOut  = cell(nM * nR, 1);
recallCV = nan(nM, nR);   recallSD = nan(nM, nR);
aucCV    = nan(nM, nR);   achFPRCV = nan(nM, nR);
c = 0;

for m = 1:nM
    for r = 1:nR
        S = U.perUEScore(oofScore(:, m), ueKeyDev, winStartDev, isPos, rules(r));
        % perUEScore preserves first-appearance order, which is the order of ueList,
        % so the fold labels line up without a join.
        assert(isequal(S.UE, string(ueList)), 'per_ue_rule:ueOrder', ...
            'Per-UE score order does not match the UE list order.');

        foldRec = nan(K, 1);  foldFPR = nan(K, 1);  foldAUC = nan(K, 1);
        for f = 1:K
            inF = (ueFold == f);
            if numel(unique(S.IsPos(~inF))) < 2 || numel(unique(S.IsPos(inF))) < 2
                continue;                    % a fold with one class cannot be scored
            end
            % Threshold from the other folds, applied to this one.
            t = U.pickThreshold(S.Score(~inF), S.IsPos(~inF), targetFPR);
            flag = S.Score(inF) >= t;
            posF = S.IsPos(inF);
            foldRec(f) = mean(flag(posF));
            foldFPR(f) = mean(flag(~posF));
            [~, ~, foldAUC(f)] = U.rocCurve( ...
                categorical(double(posF), [0 1], {'Terrestrial', 'Aerial'}), ...
                S.Score(inF), posClass);
        end

        recallCV(m, r) = mean(foldRec, 'omitnan');
        recallSD(m, r) = std(foldRec, 'omitnan');
        achFPRCV(m, r) = mean(foldFPR, 'omitnan');
        aucCV(m, r)    = mean(foldAUC, 'omitnan');

        c = c + 1;
        rowsOut{c} = {modelNames{m}, U.ruleLabel(rules(r)), string(rules(r).type), ...
                      rules(r).M, rules(r).N, recallCV(m, r), recallSD(m, r), ...
                      achFPRCV(m, r), aucCV(m, r)};
    end
    fprintf('%-22s evaluated %d candidate rules.\n', modelNames{m}, nR);
end

C = cell2table(vertcat(rowsOut{:}), 'VariableNames', ...
    {'Model', 'Rule', 'RuleType', 'M', 'N', ...
     'Recall_at_1pctFPR_mean', 'Recall_at_1pctFPR_sd', 'AchievedFPR_mean', 'PerUE_AUC_mean'});
writetable(C, fullfile(root, 'results', 'ue_rule_candidates.csv'));

%% Choose one rule per model
%  Selected on held-out fold recall at the nominal per-UE false alarm rate, with per-UE
%  AUC breaking ties. Where a persistence rule cannot beat the mean posterior the mean
%  is kept, because it has no parameters to have been fitted.
chosen = struct('type', {}, 'M', {}, 'N', {});
chosenRows = cell(nM, 1);
bestIdx = nan(nM, 1);
pooledRecall = nan(nM, 1);  pooledFPR = nan(nM, 1);
pooledAUC    = nan(nM, 1);  pooledPAUC = nan(nM, 1);

for m = 1:nM
    score = recallCV(m, :) + 1e-6 * aucCV(m, :);
    [bestScore, bestR] = max(score);
    if bestScore <= score(1) + 1e-9
        bestR = 1;                          % no persistence rule beats the mean posterior
    end
    bestIdx(m) = bestR;
    chosen(m)  = rules(bestR);

    % Pooled evaluation under the chosen rule.
    %
    % The fold-wise figures above are the right basis for selecting a rule, each rule
    % being scored on UEs whose threshold was set without them, but they are the wrong
    % basis for comparing one family against another. A fold holds around seventy-two
    % terrestrial UEs, so its false alarm rate moves in steps of about 1.4 per cent and
    % a nominal 1 per cent target cannot be resolved at all: two families reporting
    % recall "at 1 per cent" may in fact be sitting at 0.8 and 1.4 per cent, and the one
    % that overshot will look better for having done so. Pooling all folds puts every
    % family at the same three false alarms in three hundred and sixty, which is a
    % like-for-like comparison, and the partial AUC below 5 per cent removes the
    % dependence on a single discrete operating point altogether.
    Sp = U.perUEScore(oofScore(:, m), ueKeyDev, winStartDev, isPos, chosen(m));
    Yp = categorical(double(Sp.IsPos), [0 1], {'Terrestrial', 'Aerial'});
    [xp, yp, pooledAUC(m)] = U.rocCurve(Yp, Sp.Score, posClass);
    [~, pooledPAUC(m)] = U.partialAUC(xp, yp, 0.05);
    [~, pooledFPR(m), pooledRecall(m)] = U.pickThreshold(Sp.Score, Sp.IsPos, targetFPR);

    chosenRows{m} = {modelNames{m}, U.ruleLabel(rules(bestR)), string(rules(bestR).type), ...
        rules(bestR).M, rules(bestR).N, recallCV(m, bestR), recallSD(m, bestR), ...
        achFPRCV(m, bestR), aucCV(m, bestR), recallCV(m, 1), aucCV(m, 1), ...
        pooledRecall(m), pooledFPR(m), pooledAUC(m), pooledPAUC(m)};
end

Ch = cell2table(vertcat(chosenRows{:}), 'VariableNames', ...
    {'Model', 'ChosenRule', 'RuleType', 'M', 'N', ...
     'Recall_at_1pctFPR_mean', 'Recall_at_1pctFPR_sd', 'AchievedFPR_mean', ...
     'PerUE_AUC_mean', 'MeanPosterior_Recall', 'MeanPosterior_AUC', ...
     'Pooled_Recall_at_1pctFPR', 'Pooled_AchievedFPR', ...
     'Pooled_PerUE_AUC', 'Pooled_PerUE_pAUC5norm'});
writetable(Ch, fullfile(root, 'results', 'ue_rule_chosen.csv'));

%% Report
%  The achieved false alarm rate is printed beside the recall, not left in the CSV. The
%  threshold is fixed on roughly four fifths of the UEs and applied to the remaining
%  fifth, where a single false alarm is already about 1.4 per cent, so the rate achieved
%  on the held-out fold routinely differs from the nominal one and the recall figure is
%  not interpretable without it.
fprintf('\n%-22s %-22s %15s %13s %11s %10s\n', ...
    'Model', 'Chosen rule', 'Recall@1%FPR', 'AchievedFPR', 'vs mean post.', 'Per-UE AUC');
for m = 1:nM
    b = bestIdx(m);
    fprintf('%-22s %-22s  %5.3f +/-%5.3f %11.3f%% %11.3f %10.3f\n', ...
        modelNames{m}, U.ruleLabel(chosen(m)), ...
        recallCV(m, b), recallSD(m, b), 100 * achFPRCV(m, b), ...
        recallCV(m, b) - recallCV(m, 1), aucCV(m, b));
end
fprintf(['\nRecall is quoted at the nominal 1%% per-UE false alarm rate; the achieved column\n' ...
         'is what the held-out folds actually delivered and is the figure to report.\n']);
over = find(achFPRCV(sub2ind(size(achFPRCV), (1:nM)', bestIdx)) > targetFPR * 1.2);
if ~isempty(over)
    fprintf('Achieved rate exceeds the target by more than a fifth for: %s.\n', ...
        strjoin(modelNames(over), ', '));
end

%% Pooled comparison across families
%  This is the table D6.7 selects from. Every family sits at the same achieved false
%  alarm rate here, so the recalls are directly comparable, and the partial AUC is the
%  criterion because a single operating point on three hundred and sixty terrestrial UEs
%  can only separate two good families by a whole UE at a time.
fprintf('\nPooled over all folds, every family at the same achieved false alarm rate:\n');
fprintf('%-22s %13s %13s %12s %16s\n', ...
    'Model', 'Recall', 'AchievedFPR', 'Per-UE AUC', 'pAUC<5%FPR');
[~, ord] = sort(pooledPAUC, 'descend');
for m = ord'
    fprintf('%-22s %13.4f %12.3f%% %12.4f %16.4f\n', ...
        modelNames{m}, pooledRecall(m), 100 * pooledFPR(m), pooledAUC(m), pooledPAUC(m));
end
nAerUE = sum(arrayfun(@(u) any(isPos(ueKeyDev == u)), ueList));
fprintf(['Pooled recall moves in steps of 1/%d = %.4f, so a gap narrower than that between\n' ...
         'two families is not a difference the data can resolve; the partial AUC is.\n'], ...
    nAerUE, 1 / nAerUE);

save(fullfile(root, 'prepared_data', 'ue_rule.mat'), ...
     'chosen', 'rules', 'bestIdx', 'recallCV', 'recallSD', 'aucCV', 'achFPRCV', ...
     'pooledRecall', 'pooledFPR', 'pooledAUC', 'pooledPAUC', ...
     'modelNames', 'modelKeys', 'ueList', 'ueFold', 'targetFPR');

fprintf('\nSaved results/ue_rule_candidates.csv, results/ue_rule_chosen.csv and prepared_data/ue_rule.mat\n');
fprintf('Run thresholds.m next.\n');
