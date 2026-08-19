%% Phase 8 D8.2 - Each individual evasion condition against the honest baseline
%  Reads:  results/scores_ue.csv, results/thresholds_frozen.csv
%  Writes: results/evasion_individual_summary.csv, results/evasion_individual_perrun.csv, results/evasion_individual_perue.csv
%          figures/evasion_individual_paired.png
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
assert(~isempty(conds), 'p8_evasion:noConditions', ...
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
    assert(isscalar(t), 'p8_evasion:threshold', 'Expected one frozen per-UE threshold for %s.', mdl);

    H = Uue(Uue.Model == mdl & Uue.Condition == "honest" & Uue.Label == 1, :);

    for k = 1:numel(conds)
        cond = string(conds{k});
        E = Uue(Uue.Model == mdl & Uue.Condition == cond & Uue.Label == 1, :);

        % --- pair on UE identity within a run ---
        [tf, loc] = ismember(H.UEKey, E.UEKey);
        assert(all(tf), 'p8_evasion:unpairedUE', ...
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

writetable(Tsum, fullfile(C.resultsDir, 'evasion_individual_summary.csv'));
writetable(vertcat(runRows{:}), fullfile(C.resultsDir, 'evasion_individual_perrun.csv'));
writetable(vertcat(ueRows{:}),  fullfile(C.resultsDir, 'evasion_individual_perue.csv'));

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
V.saveFig(fig, fullfile(C.figureDir, 'evasion_individual_paired.png'));
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
fprintf('\nWrote results/evasion_individual_summary.csv, evasion_individual_perrun.csv, evasion_individual_perue.csv, figures/evasion_individual_paired.png\n');


%% ============================================================================
%% Report outputs
%% ============================================================================
RPT     = report_util();
figDir  = C.figureDir;
keyFile = fullfile(C.resultsDir, 'phase8_key_results.txt');
RPT.ensureDir(figDir);
palC = RPT.palette(numel(conds) + 1);

%% T8.5 What each evasion action bought the drone
recTxt = strings(height(Tsum), 1);
lgtTxt = strings(height(Tsum), 1);
pTxt   = strings(height(Tsum), 1);
for i = 1:height(Tsum)
    recTxt(i) = RPT.fmtCI(Tsum.DeltaRecall(i), Tsum.DeltaRecall_lo(i), Tsum.DeltaRecall_hi(i));
    lgtTxt(i) = RPT.fmtCI(Tsum.DeltaLogit(i), Tsum.DeltaLogit_lo(i), Tsum.DeltaLogit_hi(i), 2);
    pTxt(i)   = string(V.fmtP(Tsum.DeltaLogit_p(i)));
end
T85 = table(Tsum.Model, Tsum.Condition, Tsum.RecallHonest, Tsum.RecallEvasive, ...
    recTxt, lgtTxt, pTxt, ...
    'VariableNames', {'Model', 'Condition', 'Recall_honest', 'Recall_evasive', ...
                      'Delta_recall_95pct_CI', 'Delta_log_odds_95pct_CI', 'Signed_rank_p'});

RPT.tableFigure(T85, fullfile(figDir, 'T8_5_evasion_individual.png'), struct( ...
    'Title', sprintf('T8.5  D8.2 each evasion action against the honest baseline, %s, first %d windows', ...
                     opLab, C.nWin), ...
    'Highlight', Tsum.IsPrimary, ...
    'Note', ["";sprintf('Seed-paired on %d aerial UE-runs across %d runs, both sides truncated to the same observation length.', ...
                     Tsum.AerialUERuns(1), Tsum.Runs(1)); ...
             "Recall change is the consequence and is what the write-up quotes."; ...
             "The log-odds shift is the statistic with the resolution to support an inference, since per-seed recall"; ...
             "is often a single Bernoulli trial and its paired difference can only take -1, 0 or +1."]));

%% F8.3 The shift in detection log-odds, every family and every action
condList = string(conds);
shift = nan(numel(C.modelNames), numel(condList));
sLo   = nan(size(shift));
sHi   = nan(size(shift));
for m = 1:numel(C.modelNames)
    for k = 1:numel(condList)
        r = Tsum(Tsum.Model == string(C.modelNames{m}) & Tsum.Condition == condList(k), :);
        if isempty(r), continue; end
        shift(m, k) = r.DeltaLogit;
        sLo(m, k)   = r.DeltaLogit_lo;
        sHi(m, k)   = r.DeltaLogit_hi;
    end
end

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 820 400]);
ax  = axes('Parent', fig); hold(ax, 'on');
bh  = bar(ax, shift, 'grouped', 'EdgeColor', 'none');
for k = 1:numel(bh)
    bh(k).FaceColor = palC(k + 1, :);
    bh(k).FaceAlpha = 0.88;
    errorbar(ax, bh(k).XEndPoints, shift(:, k), shift(:, k) - sLo(:, k), sHi(:, k) - shift(:, k), ...
             'k', 'LineStyle', 'none', 'LineWidth', 0.9, 'CapSize', 3, 'HandleVisibility', 'off');
end
yline(ax, 0, '-', 'Color', [0.4 0.4 0.4], 'HandleVisibility', 'off');
set(ax, 'XTick', 1:numel(C.modelNames), 'XTickLabel', C.modelNames);
xtickangle(ax, 20);
ylabel(ax, 'Shift in per-UE detection log odds (negative = harder to detect)');
legend(ax, cellstr(condList), 'Location', 'southeast', 'Box', 'off', 'FontSize', 8, ...
       'Interpreter', 'none');
title(ax, 'F8.3  D8.2 how far each evasion action moves the detection log odds', ...
      'FontSize', 11, 'FontWeight', 'bold');
RPT.styleAxes(ax);
RPT.saveFig(fig, fullfile(figDir, 'F8_3_evasion_logodds_shift.png'));
close(fig);

%% F8.4 Per-run recall, honest against evasive
Prun = vertcat(runRows{:});
Prun = Prun(Prun.Model == string(C.primaryName), :);
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 330 * numel(conds) + 60, 380]);
tl  = tiledlayout(fig, 1, numel(conds), 'Padding', 'compact', 'TileSpacing', 'compact');
for k = 1:numel(conds)
    ax = nexttile(tl); hold(ax, 'on');
    Q = Prun(Prun.Condition == condList(k), :);
    jit = 0.03 * (rand(height(Q), 1) - 0.5);
    scatter(ax, Q.RecallHonest + jit, Q.RecallEvasive + jit, 40, palC(k + 1, :), 'filled', ...
            'MarkerFaceAlpha', 0.7);
    plot(ax, [0 1], [0 1], ':', 'Color', [0.5 0.5 0.5]);
    xlim(ax, [-0.08 1.08]); ylim(ax, [-0.08 1.08]);
    axis(ax, 'square');
    xlabel(ax, 'Recall, honest');
    if k == 1, ylabel(ax, 'Recall, evasive'); end
    title(ax, conds{k}, 'Interpreter', 'none');
    RPT.styleAxes(ax);
end
title(tl, sprintf('F8.4  Per-run recall, %s. Below the diagonal is a run the evasion helped', ...
                  C.primaryName), 'FontWeight', 'bold');
RPT.saveFig(fig, fullfile(figDir, 'F8_4_evasion_per_run_recall.png'));
close(fig);

%% Key results
lines = strings(0, 1);
Pp = Tsum(Tsum.IsPrimary, :);
lines(end + 1) = sprintf('Primary model          : %s', C.primaryName);
lines(end + 1) = sprintf('Baseline               : honest, truncated to %d windows', C.nWin);
lines(end + 1) = sprintf('Aerial UE-runs paired  : %d across %d runs', Pp.AerialUERuns(1), Pp.Runs(1));
for i = 1:height(Pp)
    lines(end + 1) = sprintf('%-18s recall %.3f -> %.3f, change %s, log-odds %s (p = %s)', ...
        Pp.Condition(i), Pp.RecallHonest(i), Pp.RecallEvasive(i), ...
        RPT.fmtCI(Pp.DeltaRecall(i), Pp.DeltaRecall_lo(i), Pp.DeltaRecall_hi(i)), ...
        RPT.fmtCI(Pp.DeltaLogit(i), Pp.DeltaLogit_lo(i), Pp.DeltaLogit_hi(i), 2), ...
        V.fmtP(Pp.DeltaLogit_p(i)));
end
RPT.logSection(keyFile, 'D8.2  Individual evasion conditions', lines);
RPT.logTable(keyFile, T85, 12);
