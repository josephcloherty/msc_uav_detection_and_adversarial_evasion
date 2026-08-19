%% Phase 8 D8.3 - The combined condition, and whether the evasion actions compound
%  Reads:  results/scores_ue.csv, results/evasion_individual_perue.csv, results/thresholds_frozen.csv
%  Writes: results/evasion_combined_summary.csv, results/evasion_combined_perue.csv, figures/evasion_combined_interaction.png
%
%  The question is whether running two evasion actions together buys the drone more than
%  running them separately would suggest, and it is asked on the log-odds scale rather
%  than on recall.
%
%  Recall is bounded in the unit interval, so "does the combined drop equal the sum of the
%  individual drops" is not a well-posed question near either end: two forty-point drops
%  cannot sum when the starting recall is fifty points, and an apparent interference would
%  then be an artefact of the ceiling rather than a property of the evasion. The log odds
%  of the per-UE score has no such boundary, which makes additivity a meaningful null and
%  a departure from it a finding.
%
%  The interaction is defined per aerial UE-run as
%
%      I = dLogit(combined) - sum over actions of dLogit(action)
%
%  where each dLogit is the evasive minus honest shift on the same paired UE-run. Evasion
%  is expected to push scores down, so the shifts are negative. I below zero means the
%  actions reinforce each other and the combination suppresses more than their sum. I above
%  zero means they interfere, most plausibly because they exploit the same feature block
%  and the second has little left to remove once the first has acted. I near zero means
%  they act on independent parts of the signature.
%
%  The recall arithmetic is reported alongside, as description. It is what the detector
%  loses and belongs in the write-up, but it is not the quantity the compounding claim
%  rests on.

%% Settings
clear; clc;
C = p8_config();
V = p8_util();

assert(~isempty(C.combinedCondition), 'p8_combined:noCombined', ...
    'No combined condition found on disk. D8.3 has nothing to test.');
combined = string(C.combinedCondition{1});
conds    = C.individualConditions;

Uue  = readtable(C.f.scoresUE, 'TextType', 'string');
Pind = readtable(fullfile(C.resultsDir, 'evasion_individual_perue.csv'), 'TextType', 'string');
Thr  = readtable(fullfile(C.resultsDir, 'thresholds_frozen.csv'), 'TextType', 'string');

opLab = string(C.opLabels{C.opIdx});
sumRows = {};  ueRows = {};

fprintf('===== D8.3 compounding =====\n');
fprintf('Combined   : %s\n', combined);
fprintf('Components : %s\n', strjoin(conds, ' + '));
fprintf('Scale      : log odds of the per-UE score, first %d windows\n\n', C.nWin);

for m = 1:numel(C.modelNames)
    mdl = string(C.modelNames{m});
    t   = Thr.Threshold(Thr.Model == mdl & Thr.Level == "PerUE" & Thr.OperatingPoint == opLab);

    H = Uue(Uue.Model == mdl & Uue.Condition == "honest"  & Uue.Label == 1, :);
    K = Uue(Uue.Model == mdl & Uue.Condition == combined & Uue.Label == 1, :);

    [tf, loc] = ismember(H.UEKey, K.UEKey);
    assert(all(tf), 'p8_combined:unpairedUE', ...
        '%d aerial UE-run(s) have no counterpart in the combined condition.', sum(~tf));

    sH = H.ScoreTrunc;   sK = K.ScoreTrunc(loc);
    fH = sH >= t;        fK = sK >= t;
    dComb  = V.logit(sK) - V.logit(sH);
    runKey = H.RunKey;

    % --- line up each individual condition's shift on the same UE-runs ---
    dEach = nan(height(H), numel(conds));
    for k = 1:numel(conds)
        Q = Pind(Pind.Model == mdl & Pind.Condition == string(conds{k}), :);
        [tf2, loc2] = ismember(H.UEKey, Q.UEKey);
        assert(all(tf2), 'p8_combined:missingIndividual', ...
            'Condition "%s" does not cover every aerial UE-run that the combined one does.', ...
            conds{k});
        dEach(:, k) = Q.DeltaLogit(loc2);
    end
    dSum = sum(dEach, 2);
    inter = dComb - dSum;

    ueRows{end+1} = table(repmat(mdl, height(H), 1), H.RunKey, H.Scenario, H.Seed, H.UEKey, ...
        sH, sK, dComb, dSum, inter, fH, fK, ...
        'VariableNames', {'Model', 'RunKey', 'Scenario', 'Seed', 'UEKey', ...
                          'ScoreHonest', 'ScoreCombined', 'DeltaLogitCombined', ...
                          'DeltaLogitSumOfActions', 'Interaction', ...
                          'FlagHonest', 'FlagCombined'}); %#ok<SAGROW>

    % --- pooled estimates with run-level cluster bootstrap ---
    [dC, dClo, dChi]    = V.clusterBoot(runKey, @(i) mean(dComb(i)), C.nBoot, C.bootSeed, C.ciLevel);
    [dS, dSlo, dShi]    = V.clusterBoot(runKey, @(i) mean(dSum(i)),  C.nBoot, C.bootSeed, C.ciLevel);
    [iE, iLo, iHi]      = V.clusterBoot(runKey, @(i) mean(inter(i)), C.nBoot, C.bootSeed, C.ciLevel);
    recStat = @(i) mean(double(fK(i))) - mean(double(fH(i)));
    [dR, dRlo, dRhi]    = V.clusterBoot(runKey, recStat, C.nBoot, C.bootSeed, C.ciLevel);

    % --- signed-rank at run level ---
    [runs, ~, g] = unique(runKey, 'stable');
    pInter = V.signRank(accumarray(g, inter, [], @mean));
    pComb  = V.signRank(accumarray(g, dComb, [], @mean));

    % --- descriptive recall arithmetic ---
    %  Sum of the individual recall drops, quoted so the bounded-scale problem is visible
    %  rather than hidden. If this sum falls below minus the honest recall it could not
    %  have been achieved by any policy and the comparison is meaningless on this scale,
    %  which is the whole reason the test is run on log odds.
    recDropEach = nan(1, numel(conds));
    for k = 1:numel(conds)
        Q = Pind(Pind.Model == mdl & Pind.Condition == string(conds{k}), :);
        recDropEach(k) = mean(double(Q.FlagEvasive)) - mean(double(Q.FlagHonest));
    end
    recDropSum = sum(recDropEach);
    sumIsAchievable = (mean(fH) + recDropSum) >= 0;

    if iE < 0, verdict = "reinforcing";
    elseif iE > 0, verdict = "interfering";
    else, verdict = "additive";
    end
    if ~isnan(iLo) && iLo <= 0 && iHi >= 0, verdict = verdict + " (interval spans zero)"; end

    sumRows{end+1} = {mdl, combined, height(H), numel(runs), t, ...
        mean(fH), mean(fK), dR, dRlo, dRhi, ...
        recDropSum, sumIsAchievable, ...
        dC, dClo, dChi, pComb, dS, dSlo, dShi, ...
        iE, iLo, iHi, pInter, verdict, m == C.primaryIdx}; %#ok<SAGROW>

    fprintf('%-22s combined %.2f vs sum %.2f, interaction %s  %s\n', ...
        mdl, dC, dS, V.fmtCI(iE, iLo, iHi, 2), verdict);
end

Tsum = cell2table(vertcat(sumRows{:}), 'VariableNames', ...
    {'Model', 'Condition', 'AerialUERuns', 'Runs', 'Threshold', ...
     'RecallHonest', 'RecallCombined', 'DeltaRecall', 'DeltaRecall_lo', 'DeltaRecall_hi', ...
     'SumOfIndividualRecallDrops', 'SumIsAchievable', ...
     'DeltaLogitCombined', 'DeltaLogitCombined_lo', 'DeltaLogitCombined_hi', 'DeltaLogitCombined_p', ...
     'DeltaLogitSum', 'DeltaLogitSum_lo', 'DeltaLogitSum_hi', ...
     'Interaction', 'Interaction_lo', 'Interaction_hi', 'Interaction_p', 'Verdict', 'IsPrimary'});

writetable(Tsum, fullfile(C.resultsDir, 'evasion_combined_summary.csv'));
writetable(vertcat(ueRows{:}), fullfile(C.resultsDir, 'evasion_combined_perue.csv'));

%% Figure: observed combined shift against the additive prediction
%  Left panel places every model's observed combined shift against the sum of its
%  individual shifts, with the diagonal as the additive null. Right panel shows the
%  per-UE interaction for the primary model, so the pooled number can be read against
%  its own spread rather than taken on its own.
fig = figure('Position', [100 100 820 400], 'Color', 'w');
tl  = tiledlayout(fig, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
pal = V.palette();

ax = nexttile(tl); hold(ax, 'on');
lims = [min([Tsum.DeltaLogitSum; Tsum.DeltaLogitCombined]) - 0.5, ...
        max([Tsum.DeltaLogitSum; Tsum.DeltaLogitCombined; 0]) + 0.5];
plot(ax, lims, lims, ':', 'Color', [0.5 0.5 0.5], 'LineWidth', 1);
for i = 1:height(Tsum)
    isP = Tsum.IsPrimary(i);
    plot(ax, Tsum.DeltaLogitSum(i), Tsum.DeltaLogitCombined(i), 'o', ...
        'MarkerSize', 6 + 3 * isP, 'LineWidth', 1.2, ...
        'MarkerFaceColor', pal(min(i, size(pal, 1)), :), 'MarkerEdgeColor', 'k');
    errorbar(ax, Tsum.DeltaLogitSum(i), Tsum.DeltaLogitCombined(i), ...
        Tsum.DeltaLogitCombined(i) - Tsum.DeltaLogitCombined_lo(i), ...
        Tsum.DeltaLogitCombined_hi(i) - Tsum.DeltaLogitCombined(i), ...
        'Color', pal(min(i, size(pal, 1)), :), 'HandleVisibility', 'off');
    text(ax, Tsum.DeltaLogitSum(i), Tsum.DeltaLogitCombined(i), ...
        ['  ' char(Tsum.Model(i))], 'FontSize', 8);
end
xlim(ax, lims); ylim(ax, lims); axis(ax, 'square');
xlabel(ax, 'Sum of individual log-odds shifts');
ylabel(ax, 'Observed combined log-odds shift');
title(ax, 'Additive null is the diagonal');
V.styleAxes(ax);

ax = nexttile(tl); hold(ax, 'on');
Pue = vertcat(ueRows{:});
Pue = Pue(Pue.Model == string(C.primaryName), :);
[runs, ~, gg] = unique(Pue.RunKey, 'stable');
jit = 0.12 * (rand(height(Pue), 1) - 0.5);
scatter(ax, 1 + jit, Pue.Interaction, 26, gg, 'filled', 'MarkerFaceAlpha', 0.65);
yline(ax, 0, '-', 'Color', [0.5 0.5 0.5]);
iRow = Tsum(Tsum.IsPrimary, :);
errorbar(ax, 1.35, iRow.Interaction, iRow.Interaction - iRow.Interaction_lo, ...
    iRow.Interaction_hi - iRow.Interaction, 's', 'Color', 'k', 'LineWidth', 1.5, ...
    'MarkerFaceColor', 'k', 'MarkerSize', 7);
text(ax, 1.42, iRow.Interaction, sprintf(' pooled %.2f', iRow.Interaction), 'FontSize', 9);
xlim(ax, [0.8 1.8]); xticks(ax, []);
ylabel(ax, 'Interaction (combined minus sum), log odds');
title(ax, sprintf('%s, %d aerial UE-runs over %d runs', ...
    C.primaryName, height(Pue), numel(runs)));
V.styleAxes(ax);

title(tl, 'D8.3 do the evasion actions compound');
V.saveFig(fig, fullfile(C.figureDir, 'evasion_combined_interaction.png'));
close(fig);

%% Report
P = Tsum(Tsum.IsPrimary, :);
fprintf('\n----- primary model: %s -----\n', C.primaryName);
fprintf('Recall  %.3f -> %.3f, change %s\n', P.RecallHonest, P.RecallCombined, ...
    V.fmtCI(P.DeltaRecall, P.DeltaRecall_lo, P.DeltaRecall_hi));
if P.SumIsAchievable
    fprintf('Sum of individual recall drops: %.3f, achievable on the recall scale.\n', ...
        P.SumOfIndividualRecallDrops);
else
    fprintf(['Sum of individual recall drops: %.3f, against an honest recall of %.3f. No ' ...
             'policy\ncould deliver that, so the recall comparison is bounded and the ' ...
             'log-odds test is the\none that carries the compounding claim.\n'], ...
        P.SumOfIndividualRecallDrops, P.RecallHonest);
end
fprintf('Log odds: combined %s, additive prediction %s\n', ...
    V.fmtCI(P.DeltaLogitCombined, P.DeltaLogitCombined_lo, P.DeltaLogitCombined_hi, 2), ...
    V.fmtCI(P.DeltaLogitSum, P.DeltaLogitSum_lo, P.DeltaLogitSum_hi, 2));
fprintf('Interaction %s, signed-rank p = %s. Verdict: %s\n', ...
    V.fmtCI(P.Interaction, P.Interaction_lo, P.Interaction_hi, 2), ...
    V.fmtP(P.Interaction_p), P.Verdict);
fprintf('\nWrote results/evasion_combined_summary.csv, evasion_combined_perue.csv, figures/evasion_combined_interaction.png\n');


%% ============================================================================
%% Report outputs
%% ============================================================================
RPT     = report_util();
figDir  = C.figureDir;
keyFile = fullfile(C.resultsDir, 'phase8_key_results.txt');
RPT.ensureDir(figDir);

%% T8.6 Does running the actions together buy more than running them apart
recTxt = strings(height(Tsum), 1);
cmbTxt = strings(height(Tsum), 1);
sumTxt = strings(height(Tsum), 1);
intTxt = strings(height(Tsum), 1);
for i = 1:height(Tsum)
    recTxt(i) = RPT.fmtCI(Tsum.DeltaRecall(i), Tsum.DeltaRecall_lo(i), Tsum.DeltaRecall_hi(i));
    cmbTxt(i) = RPT.fmtCI(Tsum.DeltaLogitCombined(i), Tsum.DeltaLogitCombined_lo(i), ...
                          Tsum.DeltaLogitCombined_hi(i), 2);
    sumTxt(i) = RPT.fmtCI(Tsum.DeltaLogitSum(i), Tsum.DeltaLogitSum_lo(i), ...
                          Tsum.DeltaLogitSum_hi(i), 2);
    intTxt(i) = RPT.fmtCI(Tsum.Interaction(i), Tsum.Interaction_lo(i), Tsum.Interaction_hi(i), 2);
end
T86 = table(Tsum.Model, Tsum.RecallHonest, Tsum.RecallCombined, recTxt, ...
    cmbTxt, sumTxt, intTxt, Tsum.Verdict, ...
    'VariableNames', {'Model', 'Recall_honest', 'Recall_combined', 'Delta_recall_95pct_CI', ...
                      'Combined_log_odds', 'Additive_prediction', 'Interaction', 'Verdict'});

RPT.tableFigure(T86, fullfile(figDir, 'T8_6_evasion_combined.png'), struct( ...
    'Title', sprintf('T8.6  D8.3 do the evasion actions compound, %s, first %d windows', opLab, C.nWin), ...
    'Highlight', Tsum.IsPrimary, ...
    'Note', ["";"Tested on log odds, not on recall: recall is bounded in [0,1] so two large drops cannot sum near the floor."; ...
             "Interaction below zero means the actions reinforce each other; above zero means they interfere."; ...
             sprintf('Sum of the individual recall drops is %.3f against an honest recall of %.3f, achievable = %d.', ...
                     Tsum.SumOfIndividualRecallDrops(find(Tsum.IsPrimary, 1)), ...
                     Tsum.RecallHonest(find(Tsum.IsPrimary, 1)), ...
                     Tsum.SumIsAchievable(find(Tsum.IsPrimary, 1)))]));

%% F8.5 Recall under every condition, primary family
condAll = [{'honest'}, conds, {char(combined)}];
recVals = nan(numel(condAll), 1);
recVals(1) = Tsum.RecallHonest(find(Tsum.IsPrimary, 1));
for k = 1:numel(conds)
    Q = Pind(Pind.Model == string(C.primaryName) & Pind.Condition == string(conds{k}), :);
    recVals(k + 1) = mean(double(Q.FlagEvasive));
end
recVals(end) = Tsum.RecallCombined(find(Tsum.IsPrimary, 1));

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 660 400]);
ax  = axes('Parent', fig); hold(ax, 'on');
palA = RPT.palette(numel(condAll));
for k = 1:numel(condAll)
    bar(ax, k, recVals(k), 0.6, 'FaceColor', palA(k, :), 'FaceAlpha', 0.88, 'EdgeColor', 'none');
    text(ax, k, recVals(k) + 0.03, sprintf('%.3f', recVals(k)), ...
         'HorizontalAlignment', 'center', 'FontSize', 9);
end
yline(ax, recVals(1), ':', 'Color', [0.4 0.4 0.4], 'Label', 'honest baseline', ...
      'FontSize', 8, 'LabelHorizontalAlignment', 'right');
set(ax, 'XTick', 1:numel(condAll), 'XTickLabel', condAll, 'TickLabelInterpreter', 'none');
xtickangle(ax, 20);
ylim(ax, [0 1.08]);
ylabel(ax, sprintf('Per-UE recall at %s', opLab));
title(ax, sprintf('F8.5  What the detector retains under every condition, %s', C.primaryName), ...
      'FontSize', 11, 'FontWeight', 'bold');
RPT.styleAxes(ax);
RPT.saveFig(fig, fullfile(figDir, 'F8_5_recall_by_condition.png'));
close(fig);

%% Key results
Pk = Tsum(Tsum.IsPrimary, :);
RPT.logSection(keyFile, 'D8.3  The combined condition and compounding', [""; ...
    sprintf('Combined condition     : %s', combined); ...
    sprintf('Components             : %s', strjoin(conds, ' + ')); ...
    sprintf('Recall                 : %.3f -> %.3f, change %s', Pk.RecallHonest, Pk.RecallCombined, ...
            RPT.fmtCI(Pk.DeltaRecall, Pk.DeltaRecall_lo, Pk.DeltaRecall_hi)); ...
    sprintf('Combined log-odds shift: %s', ...
            RPT.fmtCI(Pk.DeltaLogitCombined, Pk.DeltaLogitCombined_lo, Pk.DeltaLogitCombined_hi, 2)); ...
    sprintf('Additive prediction    : %s', ...
            RPT.fmtCI(Pk.DeltaLogitSum, Pk.DeltaLogitSum_lo, Pk.DeltaLogitSum_hi, 2)); ...
    sprintf('Interaction            : %s, signed-rank p = %s', ...
            RPT.fmtCI(Pk.Interaction, Pk.Interaction_lo, Pk.Interaction_hi, 2), V.fmtP(Pk.Interaction_p)); ...
    sprintf('Verdict                : %s', Pk.Verdict)]);
RPT.logTable(keyFile, T86, 8);
