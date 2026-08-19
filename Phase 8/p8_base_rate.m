%% Phase 8 D8.5 - Positive predictive value against assumed aerial prevalence
%  Reads:  results/holdout.csv
%  Writes: results/base_rate_curve.csv, results/base_rate_summary.csv, figures/base_rate.png
%
%  A detector holding a one per cent false positive rate against a rare positive class
%  produces mostly false alarms, and the rarer the class the worse it gets. This is the
%  base rate argument (Axelsson, 2000), and it is what turns a respectable recall figure
%  into an operational question about how many alerts a control room can absorb.
%
%  It is presented as a curve rather than a single number. Nobody knows what fraction of
%  the UEs attached to a cell near a protected site are aerial, and a point estimate of
%  positive predictive value quoted at one assumed prevalence invites exactly the
%  objection that the assumption was chosen to suit the answer. The shape of the curve
%  across four orders of magnitude is the argument, and the prevalence at which the
%  predictive value reaches one half is a single defensible number that falls out of it.
%
%  The alert load is derived from an assumed number of distinct UEs seen per cell per day,
%  which is stated on the figure rather than left in the text, because the alert figure is
%  linear in it and a reader has to be able to rescale it for their own assumption.
%
%  Both rates are taken from the honest hold-out at the truncated observation length, so
%  they are the same numbers every other Phase 8 stage works from.

%% Settings
clear; clc;
C = p8_config();
V = p8_util();

H = readtable(fullfile(C.resultsDir, 'holdout.csv'), 'TextType', 'string');
opLab = string(C.opLabels{C.opIdx});
H = H(H.Level == "PerUE" & H.Length == "Truncated" & H.OperatingPoint == opLab, :);
assert(~isempty(H), 'p8_baserate:noRows', 'No matching rows in holdout.csv; run p8_holdout.m first.');

p = C.prevalenceGrid(:);
gridRows = {};  sumRows = {};

fprintf('===== D8.5 base rate =====\n');
fprintf('Operating point : per-UE, %s, honest hold-out, first %d windows\n', opLab, C.nWin);
fprintf('Alert load      : %d distinct UEs per cell per day\n\n', C.uesPerCellPerDay);

for i = 1:height(H)
    tpr = H.TPR(i);
    fpr = H.FPR(i);

    % --- a measured rate of zero is not a rate of zero ---
    %  With this many terrestrial UE-runs a false positive count of zero is entirely
    %  consistent with a real rate close to one step. Taking it at face value would give a
    %  predictive value of one at every prevalence and would delete the very argument this
    %  deliverable exists to make. The rule of three upper bound is substituted and the
    %  substitution is recorded in the table so no figure quietly depends on it.
    fprUsed = fpr;
    substituted = false;
    if fpr == 0
        fprUsed = 3 / H.nNeg(i);
        substituted = true;
    end

    alertRate = tpr .* p + fprUsed .* (1 - p);
    ppv       = (tpr .* p) ./ max(alertRate, eps);
    ppvLo     = (H.TPR_lo(i) .* p) ./ max(H.TPR_lo(i) .* p + H.FPR_hi(i) .* (1 - p), eps);
    ppvHi     = (H.TPR_hi(i) .* p) ./ max(H.TPR_hi(i) .* p + max(H.FPR_lo(i), 0) .* (1 - p), eps);

    alertsPerDay = C.uesPerCellPerDay .* alertRate;
    falsePerDay  = C.uesPerCellPerDay .* fprUsed .* (1 - p);
    truePerDay   = C.uesPerCellPerDay .* tpr .* p;

    n = numel(p);
    gridRows{end+1} = table(repmat(H.Model(i), n, 1), p, ppv, ppvLo, ppvHi, ...
        alertsPerDay, truePerDay, falsePerDay, repmat(H.IsPrimary(i), n, 1), ...
        'VariableNames', {'Model', 'Prevalence', 'PPV', 'PPV_lo', 'PPV_hi', ...
                          'AlertsPerCellPerDay', 'TruePerCellPerDay', 'FalsePerCellPerDay', ...
                          'IsPrimary'}); %#ok<SAGROW>

    % --- break-even prevalence, where a flagged UE is as likely aerial as not ---
    pBreakEven = fprUsed / (tpr + fprUsed);

    for mk = C.prevalenceMarkers
        aR = tpr * mk + fprUsed * (1 - mk);
        sumRows{end+1} = {H.Model(i), tpr, fpr, fprUsed, substituted, H.nNeg(i), H.nPos(i), ...
            mk, (tpr * mk) / aR, C.uesPerCellPerDay * aR, ...
            C.uesPerCellPerDay * tpr * mk, C.uesPerCellPerDay * fprUsed * (1 - mk), ...
            pBreakEven, H.IsPrimary(i)}; %#ok<SAGROW>
    end
end

Tgrid = vertcat(gridRows{:});
Tsum  = cell2table(vertcat(sumRows{:}), 'VariableNames', ...
    {'Model', 'TPR', 'FPR_measured', 'FPR_used', 'FPR_substituted', ...
     'TerrestrialUERuns', 'AerialUERuns', 'Prevalence', 'PPV', ...
     'AlertsPerCellPerDay', 'TruePerCellPerDay', 'FalsePerCellPerDay', ...
     'BreakEvenPrevalence', 'IsPrimary'});

writetable(Tgrid, fullfile(C.resultsDir, 'base_rate_curve.csv'));
writetable(Tsum,  fullfile(C.resultsDir, 'base_rate_summary.csv'));

%% Figure
fig = figure('Position', [100 100 860 400], 'Color', 'w');
tl  = tiledlayout(fig, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');
pal = V.palette();

ax = nexttile(tl); hold(ax, 'on');
G = Tgrid(Tgrid.IsPrimary == 1, :);
fill(ax, [G.Prevalence; flipud(G.Prevalence)], [G.PPV_lo; flipud(G.PPV_hi)], ...
     pal(2, :), 'FaceAlpha', 0.15, 'EdgeColor', 'none', 'HandleVisibility', 'off');
for i = 1:numel(C.modelNames)
    Q = Tgrid(Tgrid.Model == string(C.modelNames{i}), :);
    lw = 1.0 + 1.2 * (i == C.primaryIdx);
    plot(ax, Q.Prevalence, Q.PPV, 'LineWidth', lw, ...
         'Color', pal(min(i, size(pal, 1)), :), 'DisplayName', C.modelNames{i});
end
yline(ax, 0.5, ':', 'Color', [0.5 0.5 0.5], 'HandleVisibility', 'off');
bp = Tsum.BreakEvenPrevalence(find(Tsum.IsPrimary == 1, 1));
xline(ax, bp, '--', 'Color', [0.7 0.2 0.2], 'HandleVisibility', 'off', ...
      'Label', sprintf('break-even %.1e', bp), 'FontSize', 8);
set(ax, 'XScale', 'log');
xlim(ax, [min(p) max(p)]); ylim(ax, [0 1]);
xlabel(ax, 'Assumed aerial prevalence among attached UEs');
ylabel(ax, 'Positive predictive value');
title(ax, 'A flagged UE is aerial with this probability');
legend(ax, 'Location', 'northwest', 'Box', 'off', 'FontSize', 8);
V.styleAxes(ax);

ax = nexttile(tl); hold(ax, 'on');
plot(ax, G.Prevalence, G.AlertsPerCellPerDay, 'LineWidth', 2, 'Color', pal(2, :), ...
     'DisplayName', 'all alerts');
plot(ax, G.Prevalence, G.FalsePerCellPerDay, '--', 'LineWidth', 1.2, 'Color', [0.7 0.2 0.2], ...
     'DisplayName', 'false alarms');
plot(ax, G.Prevalence, G.TruePerCellPerDay, '-.', 'LineWidth', 1.2, 'Color', [0.1 0.5 0.2], ...
     'DisplayName', 'true detections');
set(ax, 'XScale', 'log', 'YScale', 'log');
xlim(ax, [min(p) max(p)]);
xlabel(ax, 'Assumed aerial prevalence among attached UEs');
ylabel(ax, 'Alerts per cell per day');
title(ax, sprintf('Assuming %d UEs per cell per day', C.uesPerCellPerDay));
legend(ax, 'Location', 'northwest', 'Box', 'off', 'FontSize', 8);
V.styleAxes(ax);

title(tl, sprintf('D8.5 base rate at the %s operating point, %s', opLab, C.primaryName));
V.saveFig(fig, fullfile(C.figureDir, 'base_rate.png'));
close(fig);

%% Report
%  This deliverable is the one place a rate is the measurement rather than a derived
%  quantity: prevalence, predictive value and alert load are all rates by definition, and
%  the alert counts per cell per day are already counts. The detector's own performance is
%  still stated in UE-runs so the reader can see how few units it rests on.
P = Tsum(Tsum.IsPrimary == 1, :);
fprintf('Model %s: detected %s aerial UE-runs, flagged %s terrestrial UE-runs\n', ...
    P.Model(1), ...
    V.fmtCount(round(P.TPR(1) * P.AerialUERuns(1)), P.AerialUERuns(1)), ...
    V.fmtCount(round(P.FPR_used(1) * P.TerrestrialUERuns(1)), P.TerrestrialUERuns(1)));
if P.FPR_substituted(1)
    fprintf(['  The measured rate was zero on %d terrestrial UE-runs, so a rule of three ' ...
             'upper\n  bound of %.4f has been used. Every figure here is conservative by ' ...
             'that amount\n  and the substitution must be stated in the write-up.\n'], ...
        P.TerrestrialUERuns(1), P.FPR_used(1));
end
fprintf('  Break-even prevalence: %.3g. Below it, most alerts are false.\n\n', ...
    P.BreakEvenPrevalence(1));
fprintf('%-14s %10s %14s %14s\n', 'Prevalence', 'PPV', 'Alerts/cell/day', 'False/cell/day');
for i = 1:height(P)
    fprintf('%-14.0e %10.3f %14.1f %14.1f\n', ...
        P.Prevalence(i), P.PPV(i), P.AlertsPerCellPerDay(i), P.FalsePerCellPerDay(i));
end
fprintf('\nWrote results/base_rate_curve.csv, base_rate_summary.csv, figures/base_rate.png\n');


%% ============================================================================
%% Report outputs
%% ============================================================================
RPT     = report_util();
figDir  = C.figureDir;
keyFile = fullfile(C.resultsDir, 'phase8_key_results.txt');
RPT.ensureDir(figDir);

%% T8.9 What a flag is worth, and how many arrive
Pb = Tsum(Tsum.IsPrimary == 1, :);
T89 = table(Pb.Prevalence, Pb.PPV, Pb.AlertsPerCellPerDay, Pb.TruePerCellPerDay, ...
    Pb.FalsePerCellPerDay, ...
    'VariableNames', {'Assumed_aerial_prevalence', 'Positive_predictive_value', ...
                      'Alerts_per_cell_per_day', 'True_per_cell_per_day', ...
                      'False_per_cell_per_day'});

subNote = "The measured false positive rate was used directly.";
if Pb.FPR_substituted(1)
    subNote = sprintf(['The measured rate was zero on %d terrestrial UE-runs, so a rule-of-three upper bound ' ...
                       'of %.4f was substituted.'], Pb.TerrestrialUERuns(1), Pb.FPR_used(1));
end

RPT.tableFigure(T89, fullfile(figDir, 'T8_9_base_rate.png'), struct( ...
    'Title', sprintf('T8.9  D8.5 predictive value against assumed prevalence, %s, %s', ...
                     C.primaryName, opLab), ...
    'Note', ["";sprintf('Recall %.3f, false positive rate %.4f, break-even prevalence %.3g.', ...
                     Pb.TPR(1), Pb.FPR_used(1), Pb.BreakEvenPrevalence(1)); ...
             sprintf('Alert load assumes %d distinct UEs per cell per day and is linear in that number.', ...
                     C.uesPerCellPerDay); ...
             subNote; ...
             "Below the break-even prevalence most alerts are false, however good the recall figure looks."]));

%% F8.6 Predictive value at each assumed prevalence, every family
mk = C.prevalenceMarkers;
ppvM = nan(numel(C.modelNames), numel(mk));
for m = 1:numel(C.modelNames)
    for k = 1:numel(mk)
        v = Tsum.PPV(Tsum.Model == string(C.modelNames{m}) & ...
                     abs(Tsum.Prevalence - mk(k)) < 1e-12);
        if ~isempty(v), ppvM(m, k) = v(1); end
    end
end

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 760 400]);
ax  = axes('Parent', fig); hold(ax, 'on');
mp  = RPT.palette(numel(mk));
bh  = bar(ax, ppvM, 'grouped', 'EdgeColor', 'none');
for k = 1:numel(bh)
    bh(k).FaceColor = mp(k, :);
    bh(k).FaceAlpha = 0.88;
end
yline(ax, 0.5, ':', 'Color', [0.5 0.5 0.5], 'Label', 'as likely aerial as not', ...
      'FontSize', 8, 'HandleVisibility', 'off');
set(ax, 'XTick', 1:numel(C.modelNames), 'XTickLabel', C.modelNames);
xtickangle(ax, 20);
ylim(ax, [0 1]);
ylabel(ax, 'Positive predictive value');
legend(ax, arrayfun(@(v) sprintf('prevalence %.0e', v), mk, 'UniformOutput', false), ...
       'Location', 'northwest', 'Box', 'off', 'FontSize', 8);
title(ax, 'F8.6  A flagged UE is aerial with this probability', ...
      'FontSize', 11, 'FontWeight', 'bold');
RPT.styleAxes(ax);
RPT.saveFig(fig, fullfile(figDir, 'F8_6_ppv_by_prevalence.png'));
close(fig);

%% Key results
lines = strings(0, 1);
lines(end + 1) = sprintf('Primary model          : %s at the %s operating point', C.primaryName, opLab);
lines(end + 1) = sprintf('Recall / FPR used      : %.3f / %.4f', Pb.TPR(1), Pb.FPR_used(1));
lines(end + 1) = sprintf('Break-even prevalence  : %.3g. Below it, most alerts are false.', ...
                         Pb.BreakEvenPrevalence(1));
lines(end + 1) = sprintf('Alert-load assumption  : %d distinct UEs per cell per day', C.uesPerCellPerDay);
lines(end + 1) = subNote;
for i = 1:height(Pb)
    lines(end + 1) = sprintf('prevalence %.0e -> PPV %.3f, %.1f alerts/cell/day of which %.1f false', ...
        Pb.Prevalence(i), Pb.PPV(i), Pb.AlertsPerCellPerDay(i), Pb.FalsePerCellPerDay(i));
end
RPT.logSection(keyFile, 'D8.5  Base rate and alert load', lines);
RPT.logTable(keyFile, T89, 6);
