%% Phase 8 D8.6 - Detectability against mission cost
%  Reads:  results/scores_ue.csv, results/thresholds_frozen.csv, and the Phase 7 per-seed
%          mission cost table named in p8_config
%  Writes: results/frontier.csv, results/frontier_perrun.csv,
%          results/frontier_allmodels.csv, figures/frontier.png
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

assert(isfile(C.missionCostFile), 'p8_frontier:noCostFile', ...
    ['Mission cost table not found:\n  %s\nSet C.missionCostFile in p8_config to the ' ...
     'per-seed output of phase7_MissionCost. It is named explicitly rather than found by ' ...
     'pattern because more than one timestamped run can sit in that folder and picking ' ...
     'the newest is not the same as picking the right one.'], C.missionCostFile);

Cost = readtable(C.missionCostFile, 'TextType', 'string');
Cost.RunKey = strcat(Cost.scenario, '_', string(Cost.seed));
assert(ismember(C.costMetric, Cost.Properties.VariableNames), 'p8_frontier:noCostMetric', ...
    'The cost table has no column "%s".', C.costMetric);

profiles = intersect(C.profiles, cellstr(unique(Cost.profile)), 'stable');
assert(~isempty(profiles), 'p8_frontier:noProfiles', ...
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
fprintf('Detection   : aerial UE-runs detected per-UE at %s, first %d windows\n\n', ...
    opLab, C.nWin);

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
    warning('p8_frontier:missingCost', ...
        ['%d run/condition/profile combinations have detectability but no mission cost. ' ...
         'They are dropped from the condition means and will leave gaps in the scatter.'], ...
        nMissing);
end
writetable(Tjoin, fullfile(C.resultsDir, 'frontier_perrun.csv'));

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

            % Detectability is pooled over UE-runs, not averaged over simulation runs.
            % The two are not the same here and the difference is not small: runs carry
            % between one and six aerial UE-runs, and under lowAltitude the only
            % scenario still detected is UMi, which holds seven aerial UE-runs spread
            % across five runs. A mean of per-run recall gives those five runs 5/15 of
            % the weight, returning 8.3 of 25, where the pooled count is 7 of 25. D8.1
            % and D8.2 report pooled counts, so a run-average here would have put a
            % different number for the same quantity in two tables of the same chapter.
            detected = round(S.Recall .* S.AerialUERuns);
            pooled   = @(i) sum(detected(i)) / sum(S.AerialUERuns(i));
            [rec, ~, ~] = V.clusterBoot(S.RunKey, pooled, C.nBoot, C.bootSeed, C.ciLevel);
            rec = sum(detected) / sum(S.AerialUERuns);   % point estimate, not the boot mean

            % The interval is Clopper-Pearson on the pooled count, for the same reason
            % T8.2 uses it: at 25 of 25 every bootstrap resample returns 25 and the
            % interval collapses to a point.
            kDet = sum(detected);  nAer = sum(S.AerialUERuns);
            recLo = V.cpLo(kDet, nAer);
            recHi = V.cpHi(kDet, nAer);

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

% The detectability axis is drawn and tabulated as a count of aerial UE-runs. Recall is
% retained in the CSV because the Pareto test and the bootstrap both work on the rate.
nAerF = sum(Tjoin.AerialUERuns(Tjoin.Model == string(C.primaryName) & ...
                               Tjoin.Profile == string(C.profiles{1}) & ...
                               Tjoin.Condition == "honest"));

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

writetable(Tsum(Tsum.IsPrimary, :), fullfile(C.resultsDir, 'frontier.csv'));
writetable(Tsum, fullfile(C.resultsDir, 'frontier_allmodels.csv'));

%% Figure
fig = figure('Position', [100 100 330 * numel(profiles) 420], 'Color', 'w');
tl  = tiledlayout(fig, 1, numel(profiles), 'Padding', 'compact', 'TileSpacing', 'compact');
pal = V.palette();
condOrder = C.conditions;

for pr = 1:numel(profiles)
    prof = string(profiles{pr});
    ax = nexttile(tl); hold(ax, 'on');

    M = Tsum(Tsum.IsPrimary & Tsum.Profile == prof, :);

    % --- the front itself ---
    %  Every series on this axis is a count of the 25 aerial UE-runs in the hold-out, so
    %  the front is scaled by nAerF exactly as the markers are. Scaling the markers alone
    %  leaves the front drawn along the bottom of the axis, where it reads as an
    %  unrelated series rather than as the line joining the points.
    %
    %  The per-run scatter that used to sit behind these points has been removed. A run
    %  carries between one and six aerial UE-runs, so its count cannot share an axis
    %  scaled to twenty-five without either being projected onto a hypothetical whole
    %  hold-out or appearing as a smear near zero that looks like failure. The spread it
    %  conveyed is already in the error bars, which are a cluster bootstrap over whole
    %  runs, and the per-run detail is written to frontier_perrun.csv.
    F = M(M.ParetoOptimal, :);
    [~, ord] = sort(F.Cost);
    F = F(ord, :);
    plot(ax, F.Cost, F.Recall * nAerF, '-', 'Color', [0.25 0.25 0.25], 'LineWidth', 1.2, ...
         'HandleVisibility', 'off');

    for c = 1:numel(condOrder)
        Q = M(M.Condition == string(condOrder{c}), :);
        if isempty(Q), continue; end
        col = pal(min(c, size(pal, 1)), :);
        errorbar(ax, Q.Cost, Q.Recall * nAerF, ...
            (Q.Recall - Q.Recall_lo) * nAerF, (Q.Recall_hi - Q.Recall) * nAerF, ...
            Q.Cost - Q.Cost_lo, Q.Cost_hi - Q.Cost, 'o', 'Color', col, 'LineWidth', 1.2, ...
            'MarkerFaceColor', col, 'MarkerSize', 7 + 2 * Q.ParetoOptimal, ...
            'MarkerEdgeColor', 'k', 'CapSize', 3, 'DisplayName', C.labelOf(condOrder{c}));
    end

    xlabel(ax, sprintf('Mission cost (%s)', C.costMetric), 'Interpreter', 'none');
    if pr == 1, ylabel(ax, sprintf('Aerial UE-runs detected (of %d)', nAerF)); end
    ylim(ax, [0 nAerF * 1.05]);
    title(ax, prof, 'Interpreter', 'none');
    V.styleAxes(ax);
end
legend(ax, 'Location', 'northeast', 'Box', 'off', 'FontSize', 8);
title(tl, sprintf('D8.6 detectability against mission cost, %s, seeds %d to %d', ...
    C.primaryName, min(C.holdoutSeeds), max(C.holdoutSeeds)));
V.saveFig(fig, fullfile(C.figureDir, 'frontier.png'));
close(fig);

%% Report
fprintf('----- primary model: %s -----\n', C.primaryName);
for pr = 1:numel(profiles)
    M = Tsum(Tsum.IsPrimary & Tsum.Profile == string(profiles{pr}), :);
    fprintf('\n%s\n', profiles{pr});
    fprintf('  %-26s %20s %22s %s\n', 'Condition', 'Cost', 'Aerial detected', 'Pareto');
    for i = 1:height(M)
        mark = ' ';
        if M.ParetoOptimal(i), mark = '*'; end
        fprintf('  %-26s %20s %22s   %s\n', C.labelOf(char(M.Condition(i))), ...
            V.fmtCI(M.Cost(i), M.Cost_lo(i), M.Cost_hi(i)), ...
            sprintf('%d of %d [%d to %d]', round(M.Recall(i) * nAerF), nAerF, ...
                    floor(M.Recall_lo(i) * nAerF), ceil(M.Recall_hi(i) * nAerF)), mark);
    end
end
fprintf(['\nA starred condition is not dominated: nothing else buys as much evasion for as ' ...
         'little.\nThe honest condition is free and is always on the front, so every ' ...
         'evasion has to be\nread as a displacement from it rather than as a result on its ' ...
         'own.\n']);
fprintf('\nWrote results/frontier.csv, frontier_perrun.csv, frontier_allmodels.csv\n');
fprintf('Wrote figures/frontier.png. This is the Phase 8 exit criterion.\n');


%% ============================================================================
%% Report outputs
%% ============================================================================
RPT     = report_util();
figDir  = C.figureDir;
keyFile = fullfile(C.resultsDir, 'phase8_key_results.txt');
RPT.ensureDir(figDir);

%% T8.10 The frontier as a table, primary family
Pf = Tsum(Tsum.IsPrimary, :);
costTxt = strings(height(Pf), 1);
recTxt  = strings(height(Pf), 1);
for i = 1:height(Pf)
    costTxt(i) = RPT.fmtCI(Pf.Cost(i),   Pf.Cost_lo(i),   Pf.Cost_hi(i));
    recTxt(i)  = RPT.fmtCI(Pf.Recall(i), Pf.Recall_lo(i), Pf.Recall_hi(i));
end
for i = 1:height(Pf)
    recTxt(i) = sprintf('%d of %d [%d to %d]', round(Pf.Recall(i) * nAerF), nAerF, ...
        floor(Pf.Recall_lo(i) * nAerF), ceil(Pf.Recall_hi(i) * nAerF));
end
condLabF = arrayfun(@(s) string(C.labelOf(char(s))), Pf.Condition);
T810 = table(Pf.Profile, condLabF, Pf.Runs, costTxt, recTxt, Pf.ParetoOptimal, ...
    'VariableNames', {'Mission_profile', 'Condition', 'Runs', ...
                      'Mission_cost_95pct_CI', 'Aerial_detected', 'Pareto_optimal'});

RPT.tableFigure(T810, fullfile(figDir, 'T8_10_frontier.png'), struct( ...
    'Title', sprintf('T8.10  D8.6 detectability against mission cost, %s, %s', C.primaryName, opLab), ...
    'Highlight', Pf.ParetoOptimal, ...
    'Note', ["";"The honest condition costs nothing by construction, so every evasion is a displacement from it."; ...
             "A Pareto-optimal condition is not dominated: nothing else buys as much evasion for as little cost."; ...
             sprintf('Detectability is a count of the %d aerial UE-runs; cost is %s from Phase 7 on the same truncated %d-window span.', ...
                     nAerF, C.costMetric, C.nWin); ...
             "Detection is pooled over UE-runs, matching D8.1 and D8.2. A mean of per-run recall would not:"; ...
             "runs carry between one and six aerial UE-runs, so averaging over runs reweights the scenarios."; ...
             sprintf('Cost intervals are a %d-resample cluster bootstrap over whole runs; detection intervals are exact Clopper-Pearson.', C.nBoot)]));

%% Key results
lines = strings(0, 1);
lines(end + 1) = sprintf('Primary model          : %s', C.primaryName);
lines(end + 1) = sprintf('Cost table             : %s', C.missionCostFile);
lines(end + 1) = sprintf('Cost metric            : %s', C.costMetric);
lines(end + 1) = sprintf('Mission profiles       : %s', strjoin(profiles, ', '));
for pr = 1:numel(profiles)
    Mp = Pf(Pf.Profile == string(profiles{pr}), :);
    lines(end + 1) = sprintf('-- %s', profiles{pr});
    for i = 1:height(Mp)
        star = ' ';
        if Mp.ParetoOptimal(i), star = '*'; end
        lines(end + 1) = sprintf('   %s%-18s cost %s   recall %s', star, Mp.Condition(i), ...
            RPT.fmtCI(Mp.Cost(i), Mp.Cost_lo(i), Mp.Cost_hi(i)), ...
            RPT.fmtCI(Mp.Recall(i), Mp.Recall_lo(i), Mp.Recall_hi(i)));
    end
end
lines(end + 1) = "A starred condition is not dominated: nothing else buys as much evasion for as little.";
RPT.logSection(keyFile, 'D8.6  Detectability against mission cost', lines);
RPT.logTable(keyFile, T810, 12);

RPT.logSection(keyFile, 'Phase 8 figures written to figures/', [""; ...
    "T8_1_provenance.png                what was evaluated, with what, on what"; ...
    "T8_2_holdout_headline.png          D8.1 every family at the frozen operating point"; ...
    "T8_3_holdout_primary_lengths.png   D8.1 primary family at both observation lengths"; ...
    "T8_5_evasion_individual.png        D8.2 each evasion condition against honest"; ...
    "T8_6_evasion_by_scenario.png       D8.2 where each condition works, by scenario"; ...
    "T8_7_fpr_audit.png                 D8.4 did the operating point hold"; ...
    "T8_8_terrestrial_invariance.png    D8.4 do the terrestrial UEs move"; ...
    "T8_9_base_rate.png                 D8.5 predictive value and alert load"; ...
    "T8_10_frontier.png                 D8.6 the frontier as a table"; ...
    "T8_11_latency_under_evasion.png    D8.7 windows needed under each condition"; ...
    "F8_5_evasion_by_scenario.png       D8.2 where each condition works, by scenario"; ...
    "fpr_audit.png                      D8.4 false alarms by condition, in UE-runs"; ...
    "base_rate.png                      D8.5 PPV and alert load against prevalence"; ...
    "F8_6_ppv_by_prevalence.png         D8.5 PPV at each assumed prevalence"; ...
    "frontier.png                       D8.6 the core exhibit"; ...
    "F8_7_latency_under_evasion.png     D8.7 detection latency under evasion"; ...
    ""; ...
    "Each name above is written twice: <name>.png for the report, <name>.fig to edit."]);

fprintf('\nReport figures in %s\nKey results in %s\n', figDir, keyFile);
fprintf('Run p8_latency.m last for D8.7, the detection latency under evasion.\n');
