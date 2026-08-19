%% Phase 8 - Detection by deployment scenario, reported in UE-runs not percentages
%  Reads:  results/scores_ue.csv, results/thresholds_frozen.csv
%  Writes: figures/F8_8_scenario_breakdown.png (+ .fig)
%          figures/T8_12_scenario_counts.png   (+ .fig)
%          results/scenario_counts.csv
%
%  The pooled recall figure for the low-altitude condition hides the result rather than
%  reporting it. Broken out by deployment scenario the evasion does not degrade detection
%  uniformly, it removes it entirely in two scenarios and does nothing in the third, and
%  that is a statement about deployment geometry rather than about the classifier.
%
%  Everything here is a count of UE-runs. With twenty-five aerial UE-runs in the hold-out
%  a percentage carries three significant figures it has not earned: one UE is four points
%  of recall. Intervals are Clopper-Pearson, exact for a binomial proportion, and are
%  converted back to a count so the whole exhibit stays on one scale.

clear; clc;
root = fileparts(mfilename('fullpath'));
addpath(root); addpath(fullfile(root, 'models'));
C = p8_config();
R = report_util();

S  = readtable(fullfile(C.resultsDir, 'scores_ue.csv'),        'TextType', 'string');
Th = readtable(fullfile(C.resultsDir, 'thresholds_frozen.csv'), 'TextType', 'string');

%% The primary model at its frozen per-UE operating point
model = string(C.primaryName);
thr = Th.Threshold(Th.Model == model & Th.Level == "PerUE" & Th.OperatingPoint == "1pctFPR");
assert(isscalar(thr), 'p8_scenario_breakdown:threshold', ...
    'Expected exactly one frozen per-UE 1%% FPR threshold for %s.', model);

D = S(S.Model == model, :);
D.flag = D.ScoreTrunc >= thr;

%% Conditions, in the order the write-up presents them, with reporting labels
%  The combined condition applies a speed reduction on top of the altitude change, and
%  that action is not tested on its own, so it is named for what it does rather than
%  called "combined". Traffic reshaping is excluded in p8_config: with the traffic block
%  switched off in Phase 6 it is provably inert on these predictors, so it belongs in the
%  write-up as a null result rather than as a column in every table.
condKeys   = ["honest", "lowAltitude", "combined"];
condLabels = ["honest", "low altitude", "low altitude + low speed"];
keep = ismember(condKeys, unique(D.Condition));
condKeys = condKeys(keep);  condLabels = condLabels(keep);

scenList = ["RMa", "UMa", "UMi"];
nS = numel(scenList);  nC = numel(condKeys);

det = zeros(nS, nC);  fpc = zeros(nS, nC);
totA = zeros(nS, 1);  totT = zeros(nS, 1);
for i = 1:nS
    for j = 1:nC
        m = D.Scenario == scenList(i) & D.Condition == condKeys(j);
        a = m & D.Label == 1;   t = m & D.Label == 0;
        det(i, j) = sum(D.flag(a));
        fpc(i, j) = sum(D.flag(t));
        totA(i) = sum(a);   totT(i) = sum(t);
    end
end

%% Figure: aerial UE-runs detected, and terrestrial UE-runs falsely flagged
fig = figure('Visible', 'off', 'Position', [100 100 1150 460], 'Color', 'w');
cols = R.palette(nC);

ax1 = subplot(1, 2, 1);
hold(ax1, 'on');
bar(ax1, 1:nS, repmat(totA, 1, nC), 1, 'FaceColor', [0.90 0.90 0.90], 'EdgeColor', 'none');
hb = bar(ax1, 1:nS, det, 1);
for j = 1:nC, hb(j).FaceColor = cols(j, :); hb(j).EdgeColor = 'none'; end
for j = 1:nC
    for i = 1:nS
        text(hb(j).XEndPoints(i), det(i, j) + 0.35, sprintf('%d', det(i, j)), ...
            'HorizontalAlignment', 'center', 'FontSize', 9, 'FontWeight', 'bold');
    end
end
set(ax1, 'XTick', 1:nS, 'XTickLabel', ...
    arrayfun(@(i) sprintf('%s\n(%d aerial)', scenList(i), totA(i)), 1:nS, 'UniformOutput', false));
ylabel(ax1, 'Aerial UE-runs detected');
title(ax1, 'Aerial UE-runs detected of those present');
ylim(ax1, [0 max(totA) + 1.6]);
legend(ax1, hb, cellstr(condLabels), 'Location', 'northwest', 'FontSize', 8, 'Box', 'off');
R.styleAxes(ax1);

ax2 = subplot(1, 2, 2);
hold(ax2, 'on');
hb2 = bar(ax2, 1:nS, fpc, 1);
for j = 1:nC, hb2(j).FaceColor = cols(j, :); hb2(j).EdgeColor = 'none'; end
for j = 1:nC
    for i = 1:nS
        text(hb2(j).XEndPoints(i), fpc(i, j) + 0.06, sprintf('%d', fpc(i, j)), ...
            'HorizontalAlignment', 'center', 'FontSize', 9);
    end
end
set(ax2, 'XTick', 1:nS, 'XTickLabel', ...
    arrayfun(@(i) sprintf('%s\n(%d terrestrial)', scenList(i), totT(i)), 1:nS, 'UniformOutput', false));
ylabel(ax2, 'Terrestrial UE-runs falsely flagged');
title(ax2, 'False alarms at the same frozen threshold');
ylim(ax2, [0 max(3, max(fpc(:)) + 1)]);
R.styleAxes(ax2);

sgtitle(sprintf('F8.8  Detection by deployment scenario, %s, frozen per-UE threshold', model), ...
    'FontWeight', 'bold', 'FontSize', 12);
R.saveFig(fig, fullfile(C.figureDir, 'F8_8_scenario_breakdown.png'));
close(fig);

%% Counts table, with the interval converted back to UE-runs
rows = {};
for j = 1:nC
    for i = 1:nS
        rows(end+1, :) = {condLabels(j), scenList(i), det(i, j), totA(i), ...
                          fpc(i, j), totT(i), ""}; %#ok<SAGROW>
    end
    k = sum(det(:, j));  n = sum(totA);
    f = sum(fpc(:, j));  m = sum(totT);
    rows(end+1, :) = {condLabels(j), "all three", k, n, f, m, cpCount(k, n)}; %#ok<SAGROW>
end
T = cell2table(rows, 'VariableNames', {'Condition', 'Scenario', ...
    'AerialDetected', 'AerialPresent', 'FalseAlarms', 'TerrestrialPresent', ...
    'PooledInterval'});
writetable(T, fullfile(C.resultsDir, 'scenario_counts.csv'));

R.tableFigure(T, fullfile(C.figureDir, 'T8_12_scenario_counts.png'), struct( ...
    'Title', sprintf('T8.12  Detection by deployment scenario in UE-runs, %s', model), ...
    'Notes', { { ...
    'Counts of UE-runs, not rates. One aerial UE-run is four percentage points of recall, so a count is the honest unit.'
    'Low altitude removes detection entirely in RMa and UMa and leaves it untouched in UMi.'
    'The mechanism is base station height: 15 m is below the antenna in UMa and RMa but above it in UMi.'
    'The pooled interval is Clopper-Pearson at 95 per cent, expressed as the fewest UE-runs consistent with the data.'
    'Traffic reshaping is excluded: with the traffic block switched off in Phase 6 it is inert on these predictors.'} }));

%% Report
fprintf('\n===== Detection by deployment scenario, %s =====\n\n', model);
fprintf('%-28s %-12s %-22s %s\n', 'Condition', 'Scenario', 'Aerial detected', 'False alarms');
for j = 1:nC
    for i = 1:nS
        fprintf('%-28s %-12s %d of %-18d %d of %d\n', condLabels(j), scenList(i), ...
            det(i, j), totA(i), fpc(i, j), totT(i));
    end
    fprintf('%-28s %-12s %d of %-18d %d of %d   %s\n\n', condLabels(j), 'all three', ...
        sum(det(:, j)), sum(totA), sum(fpc(:, j)), sum(totT), cpCount(sum(det(:, j)), sum(totA)));
end
fprintf('Wrote figures/F8_8_scenario_breakdown.png and figures/T8_12_scenario_counts.png\n');
fprintf('Wrote results/scenario_counts.csv\n');


%% ---- Clopper-Pearson interval, expressed as a count of UE-runs ----
%  The exact interval for a binomial proportion, obtained by inverting the binomial test
%  rather than by assuming the estimate is normally distributed. It is the right choice
%  here for the reason the normal approximation fails: at 25 of 25 the sample variance is
%  zero, so a bootstrap or a Wald interval collapses to a point and reports certainty the
%  sample cannot support. Clopper-Pearson still returns a lower bound, because it asks
%  which true rates could plausibly have produced this count rather than how much the
%  count wobbles.
function s = cpCount(k, n)
    if n == 0, s = ""; return; end
    if k == 0
        lo = 0;
    else
        lo = betainv(0.025, k, n - k + 1);
    end
    s = sprintf('at least %d of %d (95%%)', floor(lo * n), n);
end
