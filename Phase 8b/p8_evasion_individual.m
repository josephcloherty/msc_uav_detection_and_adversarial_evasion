%% Phase 8 D8.2 - Each evasion condition against the honest baseline
%  Reads:  results/scores_ue.csv, results/thresholds_frozen.csv
%  Writes: results/evasion_individual_summary.csv, results/evasion_individual_perrun.csv, results/evasion_individual_perue.csv
%          figures/T8_5_evasion_individual.png, figures/F8_5_evasion_by_scenario.png
%
%  Every comparison is seed-paired and truncated to the same observation length, so the
%  only thing that differs between the two sides is the evasion policy. Pairing is done at
%  UE-run level, since the same UE identifiers appear in the honest and evasive runs of a
%  given seed, and then aggregated to run level for the significance test because UE-runs
%  inside one simulation run are not independent draws.
%
%  Two statistics are reported for each condition and they answer different questions.
%
%  The change in the number of aerial UE-runs detected is what the detector actually
%  loses and is the number the write-up quotes. It is also nearly all of the resolution
%  the dataset has: with twenty-five aerial UE-runs in the hold-out, and most runs
%  contributing a single one, per-seed detection is often a single Bernoulli trial and the
%  paired difference can only take the values minus one, zero and one. A signed-rank test
%  on that has very little to work with, which is a property of the experimental design
%  rather than of the evasion.
%
%  The per-UE score shift on the log-odds scale is the statistic the inference rests on.
%  It uses every aerial UE-run at full resolution instead of collapsing each to a bit and
%  it is continuous. Where the two disagree, the score shift is the more reliable signal
%  and the count is the more consequential one, and the write-up should say so.
%
%  The conditions are peers, not a decomposition. lowAltLowSpeed is a strictly more
%  aggressive posture than lowAltitude and is reported as its own condition; it is not
%  the sum of other conditions and no additivity test is attempted on it. An earlier
%  version did attempt one and the test was not computable as posed, because the folder
%  applies an action that no individual condition contains.
%
%  The per-scenario breakdown lives here rather than in a script of its own, because the
%  pooled figure for lowAltitude is the one result in Phase 8 that a pooled number
%  actively misreports: the evasion does not degrade detection evenly, it removes it in
%  two deployment types and does nothing in the third.

%% Settings
clear; clc;
C = p8_config();
V = p8_util();

Uue = readtable(C.f.scoresUE, 'TextType', 'string');
Thr = readtable(fullfile(C.resultsDir, 'thresholds_frozen.csv'), 'TextType', 'string');

conds = C.evasiveConditions;
assert(~isempty(conds), 'p8_evasion:noConditions', ...
    'No evasive conditions found. D8.2 has nothing to compare.');
condLabs = cellfun(@(n) C.labelOf(n), conds, 'UniformOutput', false);

opLab  = string(C.opLabels{C.opIdx});
sumRows = {};  runRows = {};  ueRows = {};

fprintf('===== D8.2 evasion conditions against the honest baseline =====\n');
fprintf('Conditions : %s\n', strjoin(condLabs, ', '));
fprintf('Baseline   : honest, truncated to %d windows\n', C.nWin);
fprintf('Operating  : per-UE, %s\n', opLab);
fprintf('Reported   : counts of aerial UE-runs detected\n\n');

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

        sumRows{end+1} = {mdl, cond, string(C.labelOf(cond)), height(H), numel(runs), t, ...
            sum(fH), sum(fE), sum(fH) - sum(fE), ...
            mean(fH), mean(fE), dRec, dRecLo, dRecHi, pRec, nRec, ...
            mean(V.logit(sH)), mean(V.logit(sE)), dLog, dLogLo, dLogHi, pLog, ...
            mean(sH), mean(sE), mean(dScore), m == C.primaryIdx}; %#ok<SAGROW>

        fprintf('%-22s %-26s detected %2d -> %2d of %d (%d lost)   logit shift %s\n', ...
            mdl, C.labelOf(cond), sum(fH), sum(fE), height(H), sum(fH) - sum(fE), ...
            V.fmtCI(dLog, dLogLo, dLogHi, 2));
    end
end

Tsum = cell2table(vertcat(sumRows{:}), 'VariableNames', ...
    {'Model', 'Condition', 'ConditionLabel', 'AerialUERuns', 'Runs', 'Threshold', ...
     'DetectedHonest', 'DetectedEvasive', 'DetectionsLost', ...
     'RecallHonest', 'RecallEvasive', 'DeltaRecall', 'DeltaRecall_lo', 'DeltaRecall_hi', ...
     'DeltaRecall_p', 'nPairs', ...
     'MeanLogitHonest', 'MeanLogitEvasive', 'DeltaLogit', 'DeltaLogit_lo', 'DeltaLogit_hi', ...
     'DeltaLogit_p', 'MeanScoreHonest', 'MeanScoreEvasive', 'DeltaScore', 'IsPrimary'});

writetable(Tsum, fullfile(C.resultsDir, 'evasion_individual_summary.csv'));
writetable(vertcat(runRows{:}), fullfile(C.resultsDir, 'evasion_individual_perrun.csv'));
writetable(vertcat(ueRows{:}),  fullfile(C.resultsDir, 'evasion_individual_perue.csv'));

%% Report
fprintf('\n----- primary model: %s -----\n', C.primaryName);
P = Tsum(Tsum.IsPrimary, :);
for i = 1:height(P)
    fprintf(['%-26s detected %s -> %s aerial UE-runs, %d lost\n' ...
             '%26s  log-odds shift %s (p = %s over %d runs)\n'], ...
        P.ConditionLabel(i), ...
        V.fmtCount(P.DetectedHonest(i), P.AerialUERuns(i)), ...
        V.fmtCount(P.DetectedEvasive(i), P.AerialUERuns(i)), ...
        P.DetectionsLost(i), '', ...
        V.fmtCI(P.DeltaLogit(i), P.DeltaLogit_lo(i), P.DeltaLogit_hi(i), 2), ...
        V.fmtP(P.DeltaLogit_p(i)), P.Runs(i));
end
fprintf(['\nThe count is the consequence; the log-odds shift is the statistic with the ' ...
         'resolution\nto support an inference, since per-run detection is often a single ' ...
         'Bernoulli trial.\nQuote both.\n']);
fprintf('\nWrote results/evasion_individual_summary.csv, evasion_individual_perrun.csv, evasion_individual_perue.csv\n');


%% ============================================================================
%% Report outputs
%% ============================================================================
RPT     = report_util();
figDir  = C.figureDir;
keyFile = fullfile(C.resultsDir, 'phase8_key_results.txt');
RPT.ensureDir(figDir);
palC = RPT.palette(numel(conds) + 1);

%% T8.5 What each evasion action bought the drone
detH = strings(height(Tsum), 1);
detE = strings(height(Tsum), 1);
lgtTxt = strings(height(Tsum), 1);
pTxt   = strings(height(Tsum), 1);
for i = 1:height(Tsum)
    detH(i)   = V.fmtCount(Tsum.DetectedHonest(i),  Tsum.AerialUERuns(i));
    detE(i)   = V.fmtCountCI(Tsum.DetectedEvasive(i), Tsum.AerialUERuns(i));
    lgtTxt(i) = RPT.fmtCI(Tsum.DeltaLogit(i), Tsum.DeltaLogit_lo(i), Tsum.DeltaLogit_hi(i), 2);
    pTxt(i)   = string(V.fmtP(Tsum.DeltaLogit_p(i)));
end
T85 = table(Tsum.Model, Tsum.ConditionLabel, detH, detE, Tsum.DetectionsLost, lgtTxt, pTxt, ...
    'VariableNames', {'Model', 'Condition', 'Detected_honest', 'Detected_evasive', ...
                      'Detections_lost', 'Delta_log_odds_95pct_CI', 'Signed_rank_p'});

RPT.tableFigure(T85, fullfile(figDir, 'T8_5_evasion_individual.png'), struct( ...
    'Title', sprintf('T8.5  D8.2 each evasion condition against the honest baseline, %s, first %d windows', ...
                     opLab, C.nWin), ...
    'Highlight', Tsum.IsPrimary, ...
    'Note', ["";sprintf('Seed-paired on %d aerial UE-runs across %d runs, both sides truncated to the same observation length.', ...
                     Tsum.AerialUERuns(1), Tsum.Runs(1)); ...
             "Counts of aerial UE-runs detected. Bracketed ranges are exact Clopper-Pearson 95 per cent intervals."; ...
             "The two conditions are peers: low altitude + low speed is a more aggressive posture, not a sum of the others."; ...
             "The log-odds shift is the statistic with the resolution to support an inference, since per-run detection"; ...
             "is often a single Bernoulli trial and its paired difference can only take -1, 0 or +1."]));

%% F8.5 and T8.6  Where the evasion works, by deployment scenario
%  The pooled count for low altitude is the one Phase 8 result a pooled number actively
%  misreports. Broken out by scenario the evasion does not degrade detection evenly: it
%  removes it entirely where the aerial UE descends below the base station antenna, and
%  does nothing where it does not. Fifteen metres is below the antenna in UMa and RMa and
%  above it in UMi, so the deployment type decides whether the evasion works at all.
Tue  = vertcat(ueRows{:});
Pue  = Tue(Tue.Model == string(C.primaryName), :);
scens = unique(Pue.Scenario);
allConds  = [{'honest'}, conds];
allLabels = [{'honest'}, condLabs];
detS = zeros(numel(scens), numel(allConds));
availS = zeros(numel(scens), 1);
for s = 1:numel(scens)
    Q = Pue(Pue.Scenario == scens(s) & Pue.Condition == string(conds{1}), :);
    availS(s) = height(Q);
    detS(s, 1) = sum(Q.FlagHonest);
    for k = 1:numel(conds)
        R = Pue(Pue.Scenario == scens(s) & Pue.Condition == string(conds{k}), :);
        detS(s, k + 1) = sum(R.FlagEvasive);
    end
end

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 860 440]);
ax  = axes('Parent', fig); hold(ax, 'on');

bh = bar(ax, 1:numel(scens), detS, 0.86, 'EdgeColor', 'none');
for k = 1:numel(bh)
    bh(k).FaceColor = palC(k, :);
    bh(k).FaceAlpha = 0.92;
    for s = 1:numel(scens)
        text(ax, bh(k).XEndPoints(s), detS(s, k) + 0.22, sprintf('%d', detS(s, k)), ...
            'HorizontalAlignment', 'center', 'FontSize', 9, 'FontWeight', 'bold');
    end
end

% The number of aerial UE-runs available differs by scenario (5, 13 and 7 here), so the
% ceiling is drawn per group rather than left to the reader to infer. An earlier version
% used a grey background bar for this and it read as a fourth condition.
for s = 1:numel(scens)
    plot(ax, [s - 0.47, s + 0.47], [availS(s) availS(s)], '--', ...
         'Color', [0.45 0.45 0.45], 'LineWidth', 1.1, 'HandleVisibility', 'off');
    text(ax, s + 0.47, availS(s), sprintf(' all %d', availS(s)), 'FontSize', 8, ...
         'Color', [0.35 0.35 0.35], 'VerticalAlignment', 'middle');
end

% Tick labels are single-line char. A sprintf with an embedded newline is split by MATLAB
% into consecutive tick labels rather than stacked on one tick, which silently shifts
% every scenario name one position left and drops the last scenario off the axis.
set(ax, 'XTick', 1:numel(scens), 'XTickLabel', cellstr(scens));
xlim(ax, [0.4, numel(scens) + 0.75]);
ylim(ax, [0 max(availS) * 1.22]);
ylabel(ax, 'Aerial UE-runs detected');
xlabel(ax, 'Deployment scenario');
legend(ax, bh, allLabels, 'Location', 'northoutside', 'Orientation', 'horizontal', ...
       'Box', 'off', 'FontSize', 9);
title(ax, sprintf('F8.5  Where each evasion condition works, %s, in UE-runs', C.primaryName), ...
      'FontSize', 11, 'FontWeight', 'bold');
RPT.styleAxes(ax);
RPT.saveFig(fig, fullfile(figDir, 'F8_5_evasion_by_scenario.png'));
close(fig);

scRows = cell(0, 4);
for k = 1:numel(allConds)
    for s = 1:numel(scens)
        scRows(end+1, :) = {string(allLabels{k}), scens(s), ...
            string(V.fmtCount(detS(s, k), availS(s))), availS(s) - detS(s, k)}; %#ok<SAGROW>
    end
    scRows(end+1, :) = {string(allLabels{k}), "all three", ...
        string(V.fmtCountCI(sum(detS(:, k)), sum(availS))), sum(availS) - sum(detS(:, k))}; %#ok<SAGROW>
end
T86 = cell2table(scRows, 'VariableNames', ...
    {'Condition', 'Scenario', 'Aerial_detected', 'Aerial_missed'});
writetable(T86, fullfile(C.resultsDir, 'evasion_by_scenario.csv'));
RPT.tableFigure(T86, fullfile(figDir, 'T8_6_evasion_by_scenario.png'), struct( ...
    'Title', sprintf('T8.6  D8.2 detection by deployment scenario in UE-runs, %s', C.primaryName), ...
    'Note', ["";"Low altitude removes detection entirely in RMa and UMa and leaves it untouched in UMi."; ...
             "The mechanism is antenna height: 15 m is below the base station in UMa and RMa but above it in UMi."; ...
             "Adding a speed reduction closes the UMi gap, which is where the mobility signature was carrying the result."; ...
             "The pooled row carries an exact Clopper-Pearson 95 per cent interval, expressed in UE-runs."]));

%% Key results
lines = strings(0, 1);
Pp = Tsum(Tsum.IsPrimary, :);
lines(end + 1) = sprintf('Primary model          : %s', C.primaryName);
lines(end + 1) = sprintf('Baseline               : honest, truncated to %d windows', C.nWin);
lines(end + 1) = sprintf('Aerial UE-runs paired  : %d across %d runs', Pp.AerialUERuns(1), Pp.Runs(1));
for i = 1:height(Pp)
    lines(end + 1) = sprintf('%-26s detected %s -> %s, %d lost, log-odds %s (p = %s)', ...
        Pp.ConditionLabel(i), ...
        V.fmtCount(Pp.DetectedHonest(i), Pp.AerialUERuns(i)), ...
        V.fmtCount(Pp.DetectedEvasive(i), Pp.AerialUERuns(i)), ...
        Pp.DetectionsLost(i), ...
        RPT.fmtCI(Pp.DeltaLogit(i), Pp.DeltaLogit_lo(i), Pp.DeltaLogit_hi(i), 2), ...
        V.fmtP(Pp.DeltaLogit_p(i)));
end
for k = 1:numel(allConds)
    lines(end + 1) = sprintf('%-26s by scenario  %s', allLabels{k}, ...
        strjoin(arrayfun(@(s) sprintf('%s %d/%d', scens(s), detS(s, k), availS(s)), ...
                         1:numel(scens), 'UniformOutput', false), '   '));
end
RPT.logSection(keyFile, 'D8.2  Evasion conditions', lines);
RPT.logTable(keyFile, T85, 12);
RPT.logSection(keyFile, 'D8.2  By deployment scenario', "");
RPT.logTable(keyFile, T86, 12);
