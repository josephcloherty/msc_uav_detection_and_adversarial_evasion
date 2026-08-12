%% Phase 8 D8.6 - Detectability against mission cost
%  Reads:  results/scores_ue.csv, results/thresholds_frozen.csv, and the Phase 7 per-seed
%          mission cost table named in p8_config
%  Writes: results/D86_frontier.csv, results/D86_frontier_perrun.csv,
%          results/D86_frontier_allmodels.csv, figures/D86_frontier.png
%
%  The core exhibit. Every evasion action reduces the probability of being detected and
%  costs the drone something in the mission it was flying to do, and the contribution of
%  this work is the shape of that trade-off rather than either axis on its own. An evasion
%  that halves detectability while destroying the payload link is not an evasion an
%  operator has to worry about; one that halves detectability for a few per cent of
%  throughput is.
%
%  Detectability is per-UE recall at the frozen operating point, computed on the same
%  truncated observation length as every other Phase 8 comparison. Cost is the composite
%  operational cost from Phase 7, which is zero for the honest condition by construction,
%  since a drone that is not evading pays nothing to not evade. That anchors the honest
%  point at the left edge and makes every other point a displacement from it.
%
%  Three panels, one per mission profile. The trade-off is not the same for a drone
%  loitering on reconnaissance as for one on final approach, and conditioning the core
%  exhibit on a single profile would be a choice that has to be defended in the viva for
%  no gain. The five-algorithm table carries the same quantities for every frozen family,
%  so the shape can be shown not to depend on which classifier was chosen.
%
%  Cost and detectability are joined per run, not per condition, so the scatter behind the
%  condition means is real paired evidence rather than decoration: each faint point is one
%  seed evading in one way, with what it cost and what it bought.

%% Settings
clear; clc;
C = p8_config();
V = p8_util();

Uue = readtable(C.f.scoresUE, 'TextType', 'string');
Thr = readtable(fullfile(C.resultsDir, 'thresholds_frozen.csv'), 'TextType', 'string');

assert(isfile(C.missionCostFile), 'p8_D6:noCostFile', ...
    ['Mission cost table not found:\n  %s\nSet C.missionCostFile in p8_config to the ' ...
     'per-seed output of phase7_MissionCost. It is named explicitly rather than found by ' ...
     'pattern because more than one timestamped run can sit in that folder and picking ' ...
     'the newest is not the same as picking the right one.'], C.missionCostFile);

Cost = readtable(C.missionCostFile, 'TextType', 'string');
Cost.RunKey = strcat(Cost.scenario, '_', string(Cost.seed));
assert(ismember(C.costMetric, Cost.Properties.VariableNames), 'p8_D6:noCostMetric', ...
    'The cost table has no column "%s".', C.costMetric);

profiles = intersect(C.profiles, cellstr(unique(Cost.profile)), 'stable');
assert(~isempty(profiles), 'p8_D6:noProfiles', ...
    'None of the configured mission profiles appear in the cost table.');
if numel(profiles) < numel(C.profiles)
    fprintf('Note: %d of %d configured profiles are present in the cost table.\n', ...
        numel(profiles), numel(C.profiles));
end

opLab = string(C.opLabels{C.opIdx});
fprintf('===== D8.6 detectability against mission cost =====\n');
fprintf('Cost table  : %s\n', C.missionCostFile);
fprintf('Cost metric : %s\n', C.costMetric);
fprintf('Profiles    : %s\n', strjoin(profiles, ', '));
fprintf('Detection   : per-UE recall, %s, first %d windows\n\n', opLab, C.nWin);

%% Per-run detectability for every model and condition
runRows = {};
for m = 1:numel(C.modelNames)
    mdl = string(C.modelNames{m});
    t   = Thr.Threshold(Thr.Model == mdl & Thr.Level == "PerUE" & Thr.OperatingPoint == opLab);

    for c = 1:numel(C.conditions)
        cond = string(C.conditions{c});
        S = Uue(Uue.Model == mdl & Uue.Condition == cond & Uue.Label == 1, :);
        flag = S.ScoreTrunc >= t;
        [runs, ~, g] = unique(S.RunKey, 'stable');
        runRows{end+1} = table(repmat(mdl, numel(runs), 1), repmat(cond, numel(runs), 1), ...
            runs, accumarray(g, 1, [], @sum), accumarray(g, double(flag), [], @mean), ...
            accumarray(g, S.ScoreTrunc, [], @mean), ...
            'VariableNames', {'Model', 'Condition', 'RunKey', 'AerialUERuns', ...
                              'Recall', 'MeanScore'}); %#ok<SAGROW>
    end
end
Trun = vertcat(runRows{:});

%% Attach cost, per run and per profile
%  The honest condition carries zero cost by definition and is repeated into every profile
%  so that each panel has its own anchor rather than borrowing one.
joinRows = {};
for pr = 1:numel(profiles)
    prof = string(profiles{pr});
    Cp = Cost(Cost.profile == prof, :);

    for i = 1:height(Trun)
        if Trun.Condition(i) == "honest"
            costVal = 0;
        else
            hit = Cp(Cp.condition == Trun.Condition(i) & Cp.RunKey == Trun.RunKey(i), :);
            if isempty(hit)
                costVal = NaN;
            else
                costVal = mean(hit.(C.costMetric));
            end
        end
        joinRows{end+1} = {Trun.Model(i), prof, Trun.Condition(i), Trun.RunKey(i), ...
            Trun.AerialUERuns(i), Trun.Recall(i), Trun.MeanScore(i), costVal}; %#ok<SAGROW>
    end
end
Tjoin = cell2table(vertcat(joinRows{:}), 'VariableNames', ...
    {'Model', 'Profile', 'Condition', 'RunKey', 'AerialUERuns', 'Recall', 'MeanScore', 'Cost'});

nMissing = sum(isnan(Tjoin.Cost) & Tjoin.Condition ~= "honest");
if nMissing > 0
    warning('p8_D6:missingCost', ...
        ['%d run/condition/profile combinations have detectability but no mission cost. ' ...
         'They are dropped from the condition means and will leave gaps in the scatter.'], ...
        nMissing);
end
writetable(Tjoin, fullfile(C.resultsDir, 'D86_frontier_perrun.csv'));

%% Condition means with intervals
sumRows = {};
for m = 1:numel(C.modelNames)
    mdl = string(C.modelNames{m});
    for pr = 1:numel(profiles)
        prof = string(profiles{pr});
        for c = 1:numel(C.conditions)
            cond = string(C.conditions{c});
            S = Tjoin(Tjoin.Model == mdl & Tjoin.Profile == prof & Tjoin.Condition == cond, :);
            S = S(~isnan(S.Cost), :);
            if isempty(S), continue; end

            [rec, recLo, recHi] = V.clusterBoot(S.RunKey, @(i) mean(S.Recall(i)), ...
                                                C.nBoot, C.bootSeed, C.ciLevel);
            [cst, cstLo, cstHi] = V.clusterBoot(S.RunKey, @(i) mean(S.Cost(i)), ...
                                                C.nBoot, C.bootSeed, C.ciLevel);

            sumRows{end+1} = {mdl, prof, cond, height(S), rec, recLo, recHi, ...
                cst, cstLo, cstHi, mean(S.MeanScore), m == C.primaryIdx, false}; %#ok<SAGROW>
        end
    end
end
Tsum = cell2table(vertcat(sumRows{:}), 'VariableNames', ...
    {'Model', 'Profile', 'Condition', 'Runs', ...
     'Recall', 'Recall_lo', 'Recall_hi', 'Cost', 'Cost_lo', 'Cost_hi', ...
     'MeanScore', 'IsPrimary', 'ParetoOptimal'});

%% Pareto set, from the evader's point of view
%  The evader wants low detectability and low cost, so a condition is dominated when
%  another achieves at least as little detectability for no more cost. The honest
%  condition is on the front by construction, being free, which is the point: any evasion
%  has to justify itself against doing nothing.
for m = 1:numel(C.modelNames)
    for pr = 1:numel(profiles)
        k = find(Tsum.Model == string(C.modelNames{m}) & Tsum.Profile == string(profiles{pr}));
        for a = k'
            dominated = false;
            for b = k'
                if a == b, continue; end
                if Tsum.Cost(b) <= Tsum.Cost(a) && Tsum.Recall(b) <= Tsum.Recall(a) && ...
                   (Tsum.Cost(b) < Tsum.Cost(a) || Tsum.Recall(b) < Tsum.Recall(a))
                    dominated = true;  break;
                end
            end
            Tsum.ParetoOptimal(a) = ~dominated;
        end
    end
end

writetable(Tsum(Tsum.IsPrimary, :), fullfile(C.resultsDir, 'D86_frontier.csv'));
writetable(Tsum, fullfile(C.resultsDir, 'D86_frontier_allmodels.csv'));

%% Figure
fig = figure('Position', [100 100 330 * numel(profiles) 420], 'Color', 'w');
tl  = tiledlayout(fig, 1, numel(profiles), 'Padding', 'compact', 'TileSpacing', 'compact');
pal = V.palette();
condOrder = C.conditions;

for pr = 1:numel(profiles)
    prof = string(profiles{pr});
    ax = nexttile(tl); hold(ax, 'on');

    R = Tjoin(Tjoin.Model == string(C.primaryName) & Tjoin.Profile == prof & ~isnan(Tjoin.Cost), :);
    M = Tsum(Tsum.IsPrimary & Tsum.Profile == prof, :);

    % --- per-run evidence behind the means ---
    for c = 1:numel(condOrder)
        Q = R(R.Condition == string(condOrder{c}), :);
        scatter(ax, Q.Cost, Q.Recall, 22, pal(min(c, size(pal, 1)), :), 'filled', ...
                'MarkerFaceAlpha', 0.28, 'HandleVisibility', 'off');
    end

    % --- the front itself ---
    F = M(M.ParetoOptimal, :);
    [~, ord] = sort(F.Cost);
    F = F(ord, :);
    plot(ax, F.Cost, F.Recall, '-', 'Color', [0.25 0.25 0.25], 'LineWidth', 1.2, ...
         'HandleVisibility', 'off');

    for c = 1:numel(condOrder)
        Q = M(M.Condition == string(condOrder{c}), :);
        if isempty(Q), continue; end
        col = pal(min(c, size(pal, 1)), :);
        errorbar(ax, Q.Cost, Q.Recall, Q.Recall - Q.Recall_lo, Q.Recall_hi - Q.Recall, ...
            Q.Cost - Q.Cost_lo, Q.Cost_hi - Q.Cost, 'o', 'Color', col, 'LineWidth', 1.2, ...
            'MarkerFaceColor', col, 'MarkerSize', 7 + 2 * Q.ParetoOptimal, ...
            'MarkerEdgeColor', 'k', 'CapSize', 3, 'DisplayName', condOrder{c});
    end

    xlabel(ax, sprintf('Mission cost (%s)', C.costMetric), 'Interpreter', 'none');
    if pr == 1, ylabel(ax, sprintf('Per-UE recall at %s', opLab)); end
    ylim(ax, [0 1]);
    title(ax, prof, 'Interpreter', 'none');
    V.styleAxes(ax);
end
legend(ax, 'Location', 'northeast', 'Box', 'off', 'FontSize', 8, 'Interpreter', 'none');
title(tl, sprintf('D8.6 detectability against mission cost, %s, seeds %d to %d', ...
    C.primaryName, min(C.holdoutSeeds), max(C.holdoutSeeds)));
V.saveFig(fig, fullfile(C.figureDir, 'D86_frontier.png'));
close(fig);

%% Report
fprintf('----- primary model: %s -----\n', C.primaryName);
for pr = 1:numel(profiles)
    M = Tsum(Tsum.IsPrimary & Tsum.Profile == string(profiles{pr}), :);
    fprintf('\n%s\n', profiles{pr});
    fprintf('  %-18s %20s %20s %s\n', 'Condition', 'Cost', 'Recall', 'Pareto');
    for i = 1:height(M)
        mark = ' ';
        if M.ParetoOptimal(i), mark = '*'; end
        fprintf('  %-18s %20s %20s   %s\n', M.Condition(i), ...
            V.fmtCI(M.Cost(i), M.Cost_lo(i), M.Cost_hi(i)), ...
            V.fmtCI(M.Recall(i), M.Recall_lo(i), M.Recall_hi(i)), mark);
    end
end
fprintf(['\nA starred condition is not dominated: nothing else buys as much evasion for as ' ...
         'little.\nThe honest condition is free and is always on the front, so every ' ...
         'evasion has to be\nread as a displacement from it rather than as a result on its ' ...
         'own.\n']);
fprintf('\nWrote results/D86_frontier.csv, D86_frontier_perrun.csv, D86_frontier_allmodels.csv\n');
fprintf('Wrote figures/D86_frontier.png. This is the Phase 8 exit criterion.\n');
