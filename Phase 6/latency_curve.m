%% Phase 6 D6.5 - Detection latency curve on development data
%  Reads:  prepared_data/oof_scores.mat and prepared_data/ue_rule.mat
%  Writes: results/latency_curve.csv and results/latency_curve.png
%
%  Recall at a fixed false alarm rate against the number of windows observed. This is
%  the question an operator actually asks: not how well the detector performs given a
%  whole trajectory, but how long it has to watch a UE before it can act.
%
%  The threshold is re-derived at every observation length. This matters and is easy to
%  get wrong: a per-UE score built from three windows has a different distribution from
%  one built from thirty, so carrying the full-length threshold across would report a
%  false alarm rate that drifts with observation length and would make the curve
%  uninterpretable. At each length the threshold is fixed at the nominal rate on that
%  length's own pooled out-of-fold scores, so every point on the curve sits at the same
%  operational constraint.
%
%  Windows are taken in time order from the start of each UE's trajectory, so the
%  x axis is elapsed observation and not a selection of the UE's best windows.

%% Settings
clear; clc;
root = fileparts(mfilename('fullpath'));
addpath(root);
U = phase6_util();

nominalFPR = [0.01 0.05];
maxWindows = 30;                             % beyond this the curve is flat and the
                                             % surviving UE count starts to fall away

load(fullfile(root, 'prepared_data', 'oof_scores.mat'), ...
     'oofScore', 'modelNames', 'modelKeys', 'Ydev', 'ueKeyDev', 'winStartDev', 'posClass');
load(fullfile(root, 'prepared_data', 'ue_rule.mat'), 'chosen');

isPos = (Ydev == posClass);
nM    = numel(modelNames);

% Only UEs with at least maxWindows windows are used, so the population is identical at
% every observation length and the curve reflects observation time rather than a
% changing mix of UEs.
[ueList, ~, g] = unique(ueKeyDev, 'stable');
ueLen  = accumarray(g, 1);
keepUE = ueList(ueLen >= maxWindows);
keepRow = ismember(ueKeyDev, keepUE);
fprintf('Latency curve over %d of %d UEs with at least %d windows each.\n', ...
    numel(keepUE), numel(ueList), maxWindows);

sub.score   = oofScore(keepRow, :);
sub.ueKey   = ueKeyDev(keepRow);
sub.winStart = winStartDev(keepRow);
sub.isPos   = isPos(keepRow);

Lgrid = 1:maxWindows;
rowsOut = cell(0, 8);
recall = nan(nM, numel(Lgrid), numel(nominalFPR));

for m = 1:nM
    for li = 1:numel(Lgrid)
        L = Lgrid(li);
        % The persistence window cannot be longer than what has been observed, so N is
        % capped at L and M reduced in step. At L below N the rule degrades gracefully
        % towards "M of everything seen so far".
        r = chosen(m);
        if strcmpi(r.type, 'mofn')
            r.N = min(r.N, L);
            r.M = min(r.M, r.N);
        end
        S = U.perUEScore(sub.score(:, m), sub.ueKey, sub.winStart, sub.isPos, r, L);

        for q = 1:numel(nominalFPR)
            [t, achFPR, rec, nFP, nNeg] = U.pickThreshold(S.Score, S.IsPos, nominalFPR(q));
            recall(m, li, q) = rec;
            rowsOut(end+1, :) = {modelNames{m}, L, nominalFPR(q), t, achFPR, rec, ...
                nFP, nNeg}; %#ok<SAGROW>
        end
    end
    fprintf('%-22s latency curve computed to %d windows.\n', modelNames{m}, maxWindows);
end

C = cell2table(rowsOut, 'VariableNames', ...
    {'Model', 'WindowsObserved', 'NominalFPR', 'Threshold', 'AchievedFPR', ...
     'Recall', 'FalsePositives', 'NegativeUnits'});
writetable(C, fullfile(root, 'results', 'latency_curve.csv'));

%% Report the windows needed to reach a usable recall
%  Quoted at the primary operating point. A model that never reaches the level is
%  reported as such rather than being given an extrapolated figure.
fprintf('\nWindows observed before recall first reaches a level, at 1%% per-UE FPR:\n');
fprintf('%-22s %10s %10s %10s %14s\n', 'Model', '0.50', '0.80', '0.90', 'Recall@30win');
for m = 1:nM
    r = squeeze(recall(m, :, 1));
    fprintf('%-22s %10s %10s %10s %14.3f\n', modelNames{m}, ...
        U.firstReach(r, Lgrid, 0.50), U.firstReach(r, Lgrid, 0.80), ...
        U.firstReach(r, Lgrid, 0.90), r(end));
end

%% Figure
fig = figure('Visible', 'off', 'Position', [100 100 900 400]);
for q = 1:numel(nominalFPR)
    subplot(1, numel(nominalFPR), q); hold on; grid on;
    for m = 1:nM
        plot(Lgrid, squeeze(recall(m, :, q)), '-o', 'LineWidth', 1.2, 'MarkerSize', 3);
    end
    xlabel('Windows observed');
    ylabel('Recall');
    title(sprintf('Detection latency at %.0f%% per-UE FPR', 100 * nominalFPR(q)));
    ylim([0 1]);
    if q == 1, legend(modelNames, 'Location', 'southeast', 'FontSize', 8); end
end
exportgraphics(fig, fullfile(root, 'results', 'latency_curve.png'), 'Resolution', 200);
close(fig);

fprintf('\nSaved results/latency_curve.csv and results/latency_curve.png\n');
fprintf('Run feature_importance.m next.\n');
