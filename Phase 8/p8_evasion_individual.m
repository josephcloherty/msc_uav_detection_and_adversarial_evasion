%% Phase 8 D8.2 - Each individual evasion condition against the honest baseline
%  Reads:  results/scores_ue.csv, results/thresholds_frozen.csv
%  Writes: results/D82_summary.csv, results/D82_perrun.csv, results/D82_perue.csv
%          figures/D82_paired.png
%
%  Every comparison is seed-paired and truncated to the same observation length, so the
%  only thing that differs between the two sides is the evasion policy. Pairing is done at
%  UE-run level, since the same UE identifiers appear in the honest and evasive runs of a
%  given seed, and then aggregated to run level for the significance test because UE-runs
%  inside one simulation run are not independent draws.
%
%  Two statistics are reported for each condition and they answer different questions.
%
%  The recall difference is what the detector actually loses and is the number the
%  write-up quotes. It is also nearly all of the resolution the dataset has: with so few
%  aerial UE-runs in the hold-out, and most runs contributing a single one, per-seed recall
%  is often a single Bernoulli trial and the paired difference can only take the values
%  minus one, zero and one. A signed-rank test on that has very little to work with, which
%  is a property of the experimental design rather than of the evasion.
%
%  The per-UE score shift on the log-odds scale is the statistic the inference rests on.
%  It uses every aerial UE-run at full resolution instead of collapsing each to a bit, it
%  is continuous, and it is the scale on which D8.3 asks whether the evasion actions
%  compound. Where the two disagree, the score shift is the more reliable signal and the
%  recall difference is the more consequential one, and the write-up should say so.

%% Settings
clear; clc;
C = p8_config();
V = p8_util();

Uue = readtable(C.f.scoresUE, 'TextType', 'string');
Thr = readtable(fullfile(C.resultsDir, 'thresholds_frozen.csv'), 'TextType', 'string');

conds = C.individualConditions;
assert(~isempty(conds), 'p8_D2:noConditions', ...
    'No individual evasive conditions found. D8.2 has nothing to compare.');

opLab  = string(C.opLabels{C.opIdx});
sumRows = {};  runRows = {};  ueRows = {};

fprintf('===== D8.2 individual evasion conditions =====\n');
fprintf('Conditions : %s\n', strjoin(conds, ', '));
fprintf('Baseline   : honest, truncated to %d windows\n', C.nWin);
fprintf('Operating  : per-UE, %s\n\n', opLab);

for m = 1:numel(C.modelNames)
    mdl = string(C.modelNames{m});
    t   = Thr.Threshold(Thr.Model == mdl & Thr.Level == "PerUE" & Thr.OperatingPoint == opLab);
    assert(isscalar(t), 'p8_D2:threshold', 'Expected one frozen per-UE threshold for %s.', mdl);

    H = Uue(Uue.Model == mdl & Uue.Condition == "honest" & Uue.Label == 1, :);

    for k = 1:numel(conds)
        cond = string(conds{k});
        E = Uue(Uue.Model == mdl & Uue.Condition == cond & Uue.Label == 1, :);

        % --- pair on UE identity within a run ---
        [tf, loc] = ismember(H.UEKey, E.UEKey);
        assert(all(tf), 'p8_D2:unpairedUE', ...
            ['%d aerial UE-run(s) in the honest hold-out have no counterpart in "%s". ' ...
             'Seed pairing requires the same UE identifiers on both sides.'], sum(~tf), cond);

        sH = H.ScoreTrunc;         sE = E.ScoreTrunc(loc);
        fH = sH >= t;              fE = sE >= t;
        dScore = sE - sH;
        dLogit = V.logit(sE) - V.logit(sH);
        runKey = H.RunKey;

        ueRows{end+1} = table(repmat(mdl, height(H), 1), repmat(cond, height(H), 1), ...
            H.RunKey, H.Scenario, H.Seed, H.UEKey, sH, sE, dScore, dLogit, fH, fE, ...
            'VariableNames', {'Model', 'Condition', 'RunKey', 'Scenario', 'Seed', 'UEKey', ...
                              'ScoreHonest', 'ScoreEvasive', 'DeltaScore', 'DeltaLogit', ...
                              'FlagHonest', 'FlagEvasive'}); %#ok<SAGROW>

        % --- run-level aggregates, the unit the significance test uses ---
        [runs, ~, g] = unique(runKey, 'stable');
        recH = accumarray(g, double(fH), [], @mean);
        recE = accumarray(g, double(fE), [], @mean);
        lgt  = accumarray(g, dLogit,     [], @mean);
        nAer = accumarray(g, 1,          [], @sum);

        runRows{end+1} = table(repmat(mdl, numel(runs), 1), repmat(cond, numel(runs), 1), ...
            runs, nAer, recH, recE, recE - recH, lgt, ...
            'VariableNames', {'Model', 'Condition', 'RunKey', 'AerialUERuns', ...
                              'RecallHonest', 'RecallEvasive', 'DeltaRecall', ...
                              'MeanDeltaLogit'}); %#ok<SAGROW>

        % --- pooled estimates with run-level cluster bootstrap ---
        recStat = @(idx) mean(double(fE(idx))) - mean(double(fH(idx)));
        lgtStat = @(idx) mean(dLogit(idx));
        [dRec, dRecLo, dRecHi] = V.clusterBoot(runKey, recStat, C.nBoot, C.bootSeed, C.ciLevel);
        [dLog, dLogLo, dLogHi] = V.clusterBoot(runKey, lgtStat, C.nBoot, C.bootSeed, C.ciLevel);

        % --- signed-rank at run level, on both statistics ---
        [pRec, nRec] = V.signRank(recE - recH);
        [pLog, ~]    = V.signRank(lgt);

        sumRows{end+1} = {mdl, cond, height(H), numel(runs), t, ...
            mean(fH), mean(fE), dRec, dRecLo, dRecHi, pRec, nRec, ...
            mean(V.logit(sH)), mean(V.logit(sE)), dLog, dLogLo, dLogHi, pLog, ...
            mean(sH), mean(sE), mean(dScore), m == C.primaryIdx}; %#ok<SAGROW>

        fprintf('%-22s %-18s recall %.3f -> %.3f (%s)  logit shift %s\n', ...
            mdl, cond, mean(fH), mean(fE), ...
            V.fmtCI(dRec, dRecLo, dRecHi), V.fmtCI(dLog, dLogLo, dLogHi, 2));
    end
end

Tsum = cell2table(vertcat(sumRows{:}), 'VariableNames', ...
    {'Model', 'Condition', 'AerialUERuns', 'Runs', 'Threshold', ...
     'RecallHonest', 'RecallEvasive', 'DeltaRecall', 'DeltaRecall_lo', 'DeltaRecall_hi', ...
     'DeltaRecall_p', 'nPairs', ...
     'MeanLogitHonest', 'MeanLogitEvasive', 'DeltaLogit', 'DeltaLogit_lo', 'DeltaLogit_hi', ...
     'DeltaLogit_p', 'MeanScoreHonest', 'MeanScoreEvasive', 'DeltaScore', 'IsPrimary'});

writetable(Tsum, fullfile(C.resultsDir, 'D82_summary.csv'));
writetable(vertcat(runRows{:}), fullfile(C.resultsDir, 'D82_perrun.csv'));
writetable(vertcat(ueRows{:}),  fullfile(C.resultsDir, 'D82_perue.csv'));

%% Figure: paired per-UE scores for the primary model
%  Every aerial UE-run appears as a line from its honest score to its evasive score, with
%  the frozen threshold drawn across. A line crossing the threshold downwards is a
%  detection the evasion policy bought; the plot shows how many did and how close the rest
%  came, which a single recall number cannot.
Tue = vertcat(ueRows{:});
Pue = Tue(Tue.Model == string(C.primaryName), :);
tP  = Thr.Threshold(Thr.Model == string(C.primaryName) & Thr.Level == "PerUE" & ...
                    Thr.OperatingPoint == opLab);

fig = figure('Position', [100 100 340 * numel(conds) 420], 'Color', 'w');
tl  = tiledlayout(fig, 1, numel(conds), 'Padding', 'compact', 'TileSpacing', 'compact');
pal = V.palette();

for k = 1:numel(conds)
    ax = nexttile(tl); hold(ax, 'on');
    Q = Pue(Pue.Condition == string(conds{k}), :);
    for i = 1:height(Q)
        drop = Q.ScoreEvasive(i) < Q.ScoreHonest(i);
        plot(ax, [1 2], [Q.ScoreHonest(i) Q.ScoreEvasive(i)], '-o', ...
             'Color', [pal(min(k + 1, size(pal, 1)), :) 0.55], 'MarkerSize', 3.5, ...
             'MarkerFaceColor', 'w', 'LineWidth', 0.8 + 0.4 * drop);
    end
    plot(ax, [1 2], [mean(Q.ScoreHonest) mean(Q.ScoreEvasive)], '-s', ...
         'Color', 'k', 'LineWidth', 2, 'MarkerFaceColor', 'k', 'MarkerSize', 6);
    yline(ax, tP, '--', 'Color', [0.7 0.2 0.2], 'LineWidth', 1);
    text(ax, 2.06, tP, sprintf(' threshold (%s)', opLab), 'FontSize', 8, ...
         'Color', [0.7 0.2 0.2], 'VerticalAlignment', 'middle');
    xlim(ax, [0.8 2.5]); ylim(ax, [0 1]);
    xticks(ax, [1 2]); xticklabels(ax, {'honest', conds{k}});
    if k == 1, ylabel(ax, 'Per-UE score (mean posterior)'); end
    title(ax, conds{k}, 'Interpreter', 'none');
    V.styleAxes(ax);
end
title(tl, sprintf('D8.2 paired per-UE scores, %s, first %d windows', C.primaryName, C.nWin));
V.saveFig(fig, fullfile(C.figureDir, 'D82_paired.png'));
close(fig);

%% Report
fprintf('\n----- primary model: %s -----\n', C.primaryName);
P = Tsum(Tsum.IsPrimary, :);
for i = 1:height(P)
    fprintf(['%-18s recall %.3f -> %.3f, change %s (signed-rank p = %s over %d runs)\n' ...
             '%18s  log-odds shift %s (p = %s)\n'], ...
        P.Condition(i), P.RecallHonest(i), P.RecallEvasive(i), ...
        V.fmtCI(P.DeltaRecall(i), P.DeltaRecall_lo(i), P.DeltaRecall_hi(i)), ...
        V.fmtP(P.DeltaRecall_p(i)), P.Runs(i), '', ...
        V.fmtCI(P.DeltaLogit(i), P.DeltaLogit_lo(i), P.DeltaLogit_hi(i), 2), ...
        V.fmtP(P.DeltaLogit_p(i)));
end
fprintf(['\nRecall change is the consequence; the log-odds shift is the statistic with the ' ...
         'resolution\nto support an inference. Quote both.\n']);
fprintf('\nWrote results/D82_summary.csv, D82_perrun.csv, D82_perue.csv, figures/D82_paired.png\n');
