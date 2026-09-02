% Phase 6 D6.2 - Grouped stratified cross-validation over the development runs
%  Reads:  prepared_data/phase6_data.mat
%  Writes: prepared_data/oof_scores.mat
%          results/cv_results.csv          one row per model, mean and dispersion
%          results/cv_results_perfold.csv  one row per model and fold
%
%  Folds are grouped at run level, so no seed contributes rows to both the training and
%  the validation side of any fold, and stratified on scenario and aerial prevalence, so
%  the folds are comparable to each other. Every preprocessing step is fitted on the
%  training portion of the fold and applied to the validation portion, never the other
%  way round.
%
%  The full out-of-fold score vector is retained. Every one of D6.3 to D6.6 is computed
%  from it rather than from a fresh fit, which is what keeps the decision rule, the
%  thresholds and the latency curve all describing the same set of predictions.

%% Settings
clear; clc;
rng(9999);                                  % bagging is stochastic
root = fileparts(mfilename('fullpath'));
addpath(root);
K = 5;
U = phase6_util();

load(fullfile(root, 'prepared_data', 'phase6_data.mat'), ...
     'Xdev', 'Ydev', 'runKeyDev', 'ueKeyDev', 'winStartDev', 'featureNames', 'posClass');

isPos = (Ydev == posClass);
nRow  = size(Xdev, 1);

%% Assign whole runs to folds
%  A 1 s stride on a 10 s window makes neighbouring rows about 90 per cent identical, so
%  splitting a run across the fold boundary would put near-copies of validation rows in
%  the training set and report an optimism that has nothing to do with generalisation.
runs = unique(runKeyDev);
[~, rIdx] = ismember(runKeyDev, runs);
runScen = extractBefore(runs, '_');
runPos  = accumarray(rIdx, double(isPos), [numel(runs), 1]);
runTot  = accumarray(rIdx, 1,             [numel(runs), 1]);

K = min(K, min(histcounts(categorical(runScen))));
foldOfRun = U.foldAssign(runScen, runPos, runTot, K);
foldOfRow = foldOfRun(rIdx);

fprintf('Grouped stratified %d-fold CV over %d runs (%d rows, %d predictors).\n', ...
    K, numel(runs), nRow, numel(featureNames));
fprintf('\n%-6s %-8s %-10s %-12s %s\n', 'Fold', 'Runs', 'Rows', 'AerialRows', 'Scenarios');
for f = 1:K
    m = foldOfRow == f;
    scenHere = extractBefore(runs(foldOfRun == f), '_');
    counts = arrayfun(@(s) sum(scenHere == s), unique(runScen))';
    fprintf('%-6d %-8d %-10d %-12.1f%% %s\n', f, sum(foldOfRun == f), sum(m), ...
        100 * mean(isPos(m)), mat2str(counts));
end

%% Cross-validate
M = phase6_models(numel(featureNames));
nM = numel(M);

oofScore = nan(nRow, nM);
auc   = nan(nM, K);   pauc5 = nan(nM, K);   pauc5n = nan(nM, K);
rec01 = nan(nM, K);   rec05 = nan(nM, K);   acc    = nan(nM, K);

for f = 1:K
    tr = foldOfRow ~= f;   te = foldOfRow == f;
    Xtr = Xdev(tr, :);  Ytr = Ydev(tr);
    Xte = Xdev(te, :);  Yte = Ydev(te);

    % Imputation and scaling are fitted on the training portion of this fold only.
    med = median(Xtr, 1, 'omitnan');
    med(isnan(med)) = 0;                    % guard: column all-NaN in this fold
    Xtr = U.imputeWith(Xtr, med);
    Xte = U.imputeWith(Xte, med);

    mu    = mean(Xtr, 1);
    sigma = std(Xtr, 0, 1);
    sigma(sigma == 0) = 1;
    Ztr = (Xtr - mu) ./ sigma;
    Zte = (Xte - mu) ./ sigma;

    for m = 1:nM
        if M(m).needsZ
            model = M(m).fit(Ztr, Ytr);
            s     = M(m).score(model, Zte);
        else
            model = M(m).fit(Xtr, Ytr);
            s     = M(m).score(model, Xte);
        end
        oofScore(te, m) = s;

        [x, y, auc(m, f)] = U.rocCurve(Yte, s, posClass);
        [pauc5(m, f), pauc5n(m, f)] = U.partialAUC(x, y, 0.05);
        rec01(m, f) = U.recallAtFPR(x, y, 0.01);
        rec05(m, f) = U.recallAtFPR(x, y, 0.05);
        acc(m, f)   = mean((s >= 0.5) == (Yte == posClass));
    end
    fprintf('Fold %d of %d done.\n', f, K);
end

assert(~any(isnan(oofScore), 'all'), 'run_cv:missingScore', ...
    'Some rows received no out-of-fold score; check the fold assignment.');

%% Calibration check
%  A score that ranks correctly but is not on the probability scale passes every
%  rank-based metric silently, so it has to be tested against something a rank cannot
%  satisfy. Accuracy at the 0.5 threshold falling below the majority-class rate is the
%  symptom: it means the score is systematically displaced rather than merely imprecise.
%  This is not a model-quality test and a warning here does not invalidate the AUC,
%  partial AUC or recall figures, which are rank-based; it invalidates anything read at
%  a fixed threshold and anything averaged across a UE's windows.
baseline = max(mean(isPos), 1 - mean(isPos));
for m = 1:nM
    s = oofScore(:, m);
    if mean(acc(m, :)) < baseline
        warning('run_cv:poorCalibration', ...
            ['%s scores %.3f accuracy at the 0.5 threshold against a %.3f majority-class ' ...
             'baseline, and span %.4f to %.4f. The ranking may be sound but the score is ' ...
             'not behaving as a posterior; do not quote its accuracy and treat its per-UE ' ...
             'mean with caution.'], ...
            M(m).name, mean(acc(m, :)), baseline, min(s), max(s));
    end
end

%% Score resolution check
%  Recall at a fixed false alarm rate can only be read where the ROC has a point at or
%  below that rate. A score with few distinct values may have none, in which case the
%  metric returns exactly zero, which reads as a model failure when it is a measurement
%  failure. The two are told apart by the company the zero keeps: a fold that returns no
%  recall at 1 per cent while holding a high AUC has not failed to separate the classes,
%  it has failed to offer an operating point.
for m = 1:nM
    bad = find(rec01(m, :) == 0 & auc(m, :) > 0.7);
    if ~isempty(bad)
        warning('run_cv:unmeasurableRecall', ...
            ['%s returns zero recall at 1%% FPR in fold(s) %s while holding AUC above ' ...
             '0.7 there. Its score takes only %d distinct values across %d rows, so the ' ...
             'ROC has no point at or below the target and the metric is unmeasurable ' ...
             'rather than poor. The mean and dispersion for this family are artefacts; ' ...
             'increase the score resolution and rerun before quoting them.'], ...
            M(m).name, mat2str(bad), numel(unique(oofScore(:, m))), nRow);
    end
end

%% Report
%  AUC is the headline, but the partial AUC below a 5 per cent false alarm rate is the
%  number that matters operationally: at network scale a detector is only usable in the
%  left-hand edge of the ROC, and two models with the same full AUC can differ sharply
%  there. Dispersion is across folds and is a statement about run-to-run variation, not
%  about sampling error within a fold.
fprintf('\n%-22s %15s %15s %15s %15s\n', ...
    'Model', 'AUC', 'pAUC<5%FPR', 'Recall@1%FPR', 'Recall@5%FPR');
for m = 1:nM
    fprintf('%-22s  %5.3f +/-%5.3f  %5.3f +/-%5.3f  %5.3f +/-%5.3f  %5.3f +/-%5.3f\n', ...
        M(m).name, mean(auc(m, :)), std(auc(m, :)), ...
        mean(pauc5n(m, :)), std(pauc5n(m, :)), ...
        mean(rec01(m, :)), std(rec01(m, :)), ...
        mean(rec05(m, :)), std(rec05(m, :)));
end
fprintf('\npAUC is normalised by the 0.05 FPR width, so it reads as mean recall over that range.\n');

%% Save the summary and the per-fold detail
R = table({M.name}', mean(auc, 2), std(auc, 0, 2), ...
    mean(pauc5, 2), std(pauc5, 0, 2), mean(pauc5n, 2), std(pauc5n, 0, 2), ...
    mean(rec01, 2), std(rec01, 0, 2), mean(rec05, 2), std(rec05, 0, 2), ...
    mean(acc, 2), std(acc, 0, 2), ...
    'VariableNames', {'Model', 'AUC_mean', 'AUC_sd', ...
    'pAUC5_mean', 'pAUC5_sd', 'pAUC5norm_mean', 'pAUC5norm_sd', ...
    'Recall_at_1pctFPR_mean', 'Recall_at_1pctFPR_sd', ...
    'Recall_at_5pctFPR_mean', 'Recall_at_5pctFPR_sd', ...
    'Accuracy_at_0p5_mean', 'Accuracy_at_0p5_sd'});
R = sortrows(R, 'pAUC5norm_mean', 'descend');
writetable(R, fullfile(root, 'results', 'cv_results.csv'));

[~, ff] = ndgrid(1:nM, 1:K);
P = table(reshape(repmat({M.name}', 1, K), [], 1), ff(:), ...
    auc(:), pauc5(:), pauc5n(:), rec01(:), rec05(:), acc(:), ...
    'VariableNames', {'Model', 'Fold', 'AUC', 'pAUC5', 'pAUC5norm', ...
    'Recall_at_1pctFPR', 'Recall_at_5pctFPR', 'Accuracy_at_0p5'});
P = sortrows(P, {'Model', 'Fold'});
writetable(P, fullfile(root, 'results', 'cv_results_perfold.csv'));

%% Retain the full out-of-fold score vector
%  D6.3 to D6.6 all read this file, so the decision rule, the thresholds, the latency
%  curve and the importance ranking are computed on one common set of predictions.
modelNames = {M.name}';
modelKeys  = {M.key}';
save(fullfile(root, 'prepared_data', 'oof_scores.mat'), ...
    'oofScore', 'modelNames', 'modelKeys', 'Ydev', 'ueKeyDev', 'runKeyDev', ...
    'winStartDev', 'foldOfRow', 'foldOfRun', 'runs', 'K', 'posClass');

fprintf('\nSaved results/cv_results.csv, results/cv_results_perfold.csv and prepared_data/oof_scores.mat\n');
fprintf('Run per_ue_rule.m next.\n');


%% ============================================================================
%% Report outputs
%  The console block above is the same evidence, but it disappears when the next
%  stage clears. These are the versions that go in the report.
%% ============================================================================
RPT     = report_util();
figDir  = fullfile(root, 'figures');
keyFile = fullfile(root, 'results', 'phase6_key_results.txt');
RPT.ensureDir(figDir);
pal = RPT.palette(nM);

%% T6.3 Cross-validation summary, one row per family
cvMean = [R.AUC_mean, R.pAUC5norm_mean, R.Recall_at_1pctFPR_mean, R.Recall_at_5pctFPR_mean];
cvSD   = [R.AUC_sd,   R.pAUC5norm_sd,   R.Recall_at_1pctFPR_sd,   R.Recall_at_5pctFPR_sd];
cvTxt  = strings(nM, 4);
for i = 1:nM
    for j = 1:4
        cvTxt(i, j) = RPT.pmSD(cvMean(i, j), cvSD(i, j));
    end
end
Tcv = table(string(R.Model), cvTxt(:, 1), cvTxt(:, 2), cvTxt(:, 3), cvTxt(:, 4), ...
    'VariableNames', {'Model', 'AUC', 'pAUC_below_5pct_FPR', ...
                      'Recall_at_1pct_FPR', 'Recall_at_5pct_FPR'});

RPT.tableFigure(Tcv, fullfile(figDir, 'T6_3_cv_results.png'), struct( ...
    'Title', sprintf('T6.3  Grouped %d-fold cross-validation, %d development runs', K, numel(runs)), ...
    'Highlight', [true; false(nM - 1, 1)], ...
    'Note', ["";"Dispersion is across folds and describes run-to-run variation, not sampling error within a fold."; ...
             "Rows are ordered by the normalised partial AUC below a 5% false alarm rate, which is the selection criterion."; ...
             "pAUC is normalised by the 0.05 FPR width, so it reads as mean recall over that range."]));

%% F6.2 The four headline metrics side by side
vals = [R.AUC_mean, R.pAUC5norm_mean, R.Recall_at_1pctFPR_mean, R.Recall_at_5pctFPR_mean];
errs = [R.AUC_sd,   R.pAUC5norm_sd,   R.Recall_at_1pctFPR_sd,   R.Recall_at_5pctFPR_sd];
metricNames = {'AUC', 'pAUC<5% FPR', 'Recall @1% FPR', 'Recall @5% FPR'};

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 860 420]);
ax  = axes('Parent', fig); hold(ax, 'on');
bh  = bar(ax, vals, 'grouped', 'EdgeColor', 'none');
mp  = RPT.palette(numel(metricNames));
for i = 1:numel(bh)
    bh(i).FaceColor = mp(i, :);
    bh(i).FaceAlpha = 0.85;
    errorbar(ax, bh(i).XEndPoints, vals(:, i), errs(:, i), 'k', 'LineStyle', 'none', ...
             'LineWidth', 0.8, 'CapSize', 3, 'HandleVisibility', 'off');
end
set(ax, 'XTick', 1:nM, 'XTickLabel', R.Model);
xtickangle(ax, 15);
ylim(ax, [0 1.05]);
ylabel(ax, 'Metric value');
legend(ax, metricNames, 'Location', 'southoutside', 'Orientation', 'horizontal', 'Box', 'off');
title(ax, 'F6.2  Cross-validated performance of the five classifier families', ...
      'FontSize', 11, 'FontWeight', 'bold');
RPT.styleAxes(ax);
RPT.saveFig(fig, fullfile(figDir, 'F6_2_cv_metric_comparison.png'));
close(fig);

%% F6.3 Fold-to-fold dispersion
%  A mean with a standard deviation hides whether one fold is carrying the result.
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 880 380]);
tl  = tiledlayout(fig, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
panels = {auc, 'AUC'; pauc5n, 'pAUC below 5% FPR'};
for q = 1:2
    ax = nexttile(tl); hold(ax, 'on');
    Yv = panels{q, 1};
    for m = 1:nM
        plot(ax, 1:K, Yv(m, :), '-o', 'LineWidth', 1.2, 'MarkerSize', 4, ...
             'Color', pal(m, :), 'MarkerFaceColor', pal(m, :), 'DisplayName', M(m).name);
    end
    xlim(ax, [0.7 K + 0.3]);
    set(ax, 'XTick', 1:K);
    xlabel(ax, 'Fold');
    ylabel(ax, panels{q, 2});
    title(ax, panels{q, 2});
    RPT.styleAxes(ax);
end
legend(ax, 'Location', 'southeast', 'Box', 'off', 'FontSize', 8);
title(tl, 'F6.3  Fold-to-fold dispersion, whole runs held out together', ...
      'FontWeight', 'bold');
RPT.saveFig(fig, fullfile(figDir, 'F6_3_cv_fold_dispersion.png'));
close(fig);

%% F6.4 Pooled out-of-fold ROC
%  Every score here came from a model that had not seen the run it came from, so this
%  is the honest development-set ROC and not a resubstitution curve.
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 880 400]);
tl  = tiledlayout(fig, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
zoomTo = [1 0.05];
for q = 1:2
    ax = nexttile(tl); hold(ax, 'on');
    for m = 1:nM
        [xr, yr, ar] = U.rocCurve(Ydev, oofScore(:, m), posClass);
        plot(ax, xr, yr, 'LineWidth', 1.3, 'Color', pal(m, :), ...
             'DisplayName', sprintf('%s (AUC %.3f)', M(m).name, ar));
    end
    plot(ax, [0 1], [0 1], ':', 'Color', [0.6 0.6 0.6], 'HandleVisibility', 'off');
    xline(ax, 0.01, '--', 'Color', [0.7 0.2 0.2], 'HandleVisibility', 'off');
    xlim(ax, [0 zoomTo(q)]); ylim(ax, [0 1]);
    xlabel(ax, 'False positive rate');
    ylabel(ax, 'True positive rate');
    if q == 1
        title(ax, 'Full range');
    else
        title(ax, 'The region an operator can work in');
        legend(ax, 'Location', 'southeast', 'Box', 'off', 'FontSize', 8);
    end
    RPT.styleAxes(ax);
end
title(tl, 'F6.4  Pooled out-of-fold ROC, window level', 'FontWeight', 'bold');
RPT.saveFig(fig, fullfile(figDir, 'F6_4_oof_roc.png'));
close(fig);

%% F6.5 Out-of-fold score distributions
%  A family can rank well and still put every window on one side of 0.5. That is
%  invisible in an AUC and decisive for anything read at a fixed threshold.
nCol = min(3, nM);
nRowP = ceil(nM / nCol);
fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 300 * nCol, 260 * nRowP]);
tl  = tiledlayout(fig, nRowP, nCol, 'Padding', 'compact', 'TileSpacing', 'compact');
for m = 1:nM
    ax = nexttile(tl); hold(ax, 'on');
    edges = linspace(0, 1, 41);
    histogram(ax, oofScore(~isPos, m), edges, 'Normalization', 'probability', ...
              'FaceColor', [0.35 0.35 0.35], 'EdgeColor', 'none', 'FaceAlpha', 0.75, ...
              'DisplayName', 'Terrestrial');
    histogram(ax, oofScore(isPos, m), edges, 'Normalization', 'probability', ...
              'FaceColor', [0.00 0.45 0.70], 'EdgeColor', 'none', 'FaceAlpha', 0.70, ...
              'DisplayName', 'Aerial');
    xline(ax, 0.5, '--', 'Color', [0.7 0.2 0.2], 'HandleVisibility', 'off');
    xlim(ax, [0 1]);
    xlabel(ax, 'Out-of-fold posterior');
    ylabel(ax, 'Fraction of windows');
    title(ax, M(m).name, 'FontSize', 10);
    if m == 1, legend(ax, 'Location', 'north', 'Box', 'off', 'FontSize', 8); end
    RPT.styleAxes(ax);
end
title(tl, 'F6.5  Out-of-fold score distributions by class, dashed line at 0.5', ...
      'FontWeight', 'bold');
RPT.saveFig(fig, fullfile(figDir, 'F6_5_oof_score_distributions.png'));
close(fig);

%% Key results
RPT.logSection(keyFile, 'D6.2  Cross-validation', [""; ...
    sprintf('Design                : grouped stratified %d-fold, whole runs held out together', K); ...
    sprintf('Rows / predictors     : %d windows, %d predictors', nRow, numel(featureNames)); ...
    sprintf('Best by pAUC<5%%FPR    : %s at %.4f', R.Model{1}, R.pAUC5norm_mean(1)); ...
    sprintf('Best by AUC           : %s at %.4f', ...
            R.Model{find(R.AUC_mean == max(R.AUC_mean), 1)}, max(R.AUC_mean)); ...
    sprintf('Best recall at 1%% FPR : %s at %.4f', ...
            R.Model{find(R.Recall_at_1pctFPR_mean == max(R.Recall_at_1pctFPR_mean), 1)}, ...
            max(R.Recall_at_1pctFPR_mean))]);
RPT.logTable(keyFile, Tcv, 10);
