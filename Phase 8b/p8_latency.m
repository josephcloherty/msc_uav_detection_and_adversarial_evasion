%% Phase 8 D8.7 - Detection latency under evasion
%  Reads:  results/scores_window.csv, results/thresholds_frozen.csv, models/frozen_*.mat
%  Writes: results/latency_under_evasion.csv
%          figures/F8_7_latency_under_evasion.png
%          figures/T8_11_latency_under_evasion.png
%
%  Phase 6 asks how long the detector has to watch a UE before it can act. This asks
%  the same question of a UE that is trying not to be seen. Recall against windows
%  observed, one curve per condition, on the hold-out. It answers "does evasion buy the
%  drone time" as well as "does it buy the drone misses", and the two are different
%  claims: an evasion that leaves the final recall untouched but doubles the observation
%  needed to reach it has still bought the operator something.
%
%  The threshold is the frozen one and is never re-derived here. Phase 6's latency curve
%  re-derives at every observation length because it is working on development data and
%  can; doing that on the hold-out would be fitting an operating point to the test set.
%  The consequence is that the achieved false positive rate drifts with observation
%  length, so it is plotted beside the recall rather than assumed away. A recall gain
%  that arrives with an FPR gain is not a gain.
%
%  The persistence window of an M-of-N rule cannot be longer than what has been
%  observed, so N is capped at L and M reduced in step, exactly as in Phase 6.

%% Settings
clear; clc;
C   = p8_config();
U   = phase6_util();
RPT = report_util();

W   = readtable(C.f.scoresWindow, 'TextType', 'string');
Thr = readtable(fullfile(C.resultsDir, 'thresholds_frozen.csv'), 'TextType', 'string');
assert(~isempty(W), 'p8_latency:noScores', ...
    'No window scores found. Run p8_score.m before this stage.');

opLab  = string(C.opLabels{C.opIdx});
figDir = C.figureDir;
keyFile = fullfile(C.resultsDir, 'phase8_key_results.txt');
RPT.ensureDir(figDir);

%% The decision rule each frozen pipeline carries
ruleOf   = cell(numel(C.modelFiles), 1);
ruleName = cell(numel(C.modelFiles), 1);
for m = 1:numel(C.modelFiles)
    Sm = load(C.modelFiles{m}, 'pipeline');
    ruleOf{m}   = Sm.pipeline.rule;
    ruleName{m} = Sm.pipeline.name;
end

Lgrid = 1:C.nWin;
rows  = {};

fprintf('===== D8.7 detection latency under evasion =====\n');
fprintf('Conditions  : %s\n', strjoin(C.conditions, ', '));
fprintf('Threshold   : frozen per-UE, %s, never re-derived on hold-out data\n', opLab);
fprintf('Lengths     : 1 to %d windows\n\n', C.nWin);

for m = 1:numel(C.modelNames)
    mdl = string(C.modelNames{m});
    t   = Thr.Threshold(Thr.Model == mdl & Thr.Level == "PerUE" & ...
                        Thr.OperatingPoint == opLab);
    assert(isscalar(t), 'p8_latency:threshold', ...
        'Expected one frozen per-UE threshold for %s.', mdl);
    ri = find(strcmp(ruleName, C.modelNames{m}), 1);

    for c = 1:numel(C.conditions)
        cond = string(C.conditions{c});
        S = W(W.Model == mdl & W.Condition == cond, :);
        assert(~isempty(S), 'p8_latency:noRows', ...
            'No window scores for %s under "%s".', mdl, cond);

        sc = S.Score;
        ue = S.UEKey;
        ws = S.WinStart_s;
        ip = S.Label == 1;

        for li = 1:numel(Lgrid)
            L = Lgrid(li);
            r = ruleOf{ri};
            if strcmpi(r.type, 'mofn')
                r.N = min(r.N, L);
                r.M = min(r.M, r.N);
            end
            P = U.perUEScore(sc, ue, ws, ip, r, L);
            flag = P.Score >= t;
            rows{end + 1} = {mdl, cond, L, t, ...
                mean(flag(P.IsPos)), mean(flag(~P.IsPos)), ...
                sum(P.IsPos), sum(~P.IsPos), m == C.primaryIdx}; %#ok<SAGROW>
        end
    end
    fprintf('%-22s done\n', mdl);
end

T = cell2table(vertcat(rows{:}), 'VariableNames', ...
    {'Model', 'Condition', 'WindowsObserved', 'Threshold', 'Recall', 'FPR', ...
     'AerialUERuns', 'TerrestrialUERuns', 'IsPrimary'});
writetable(T, fullfile(C.resultsDir, 'latency_under_evasion.csv'));

%% F8.7 The curves
Pt  = T(T.IsPrimary, :);
pal = RPT.palette(numel(C.conditions));
halfLine = ceil(0.50 * max(Pt.AerialUERuns));
mostLine = ceil(0.80 * max(Pt.AerialUERuns));

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 940 400]);
tl  = tiledlayout(fig, 1, 2, 'Padding', 'compact', 'TileSpacing', 'compact');

%  Both axes are counts of UE-runs. Recall and false positive rate are the same curves
%  multiplied by a constant, but drawn on a 0 to 25 axis the reader can see that the
%  low-altitude curve never rises past a handful of UE-runs, which a 0 to 1 axis makes
%  look like a respectable fraction.
nAerP = max(Pt.AerialUERuns);
nNegP = max(Pt.TerrestrialUERuns);
panels = {'Recall', sprintf('Aerial UE-runs detected (of %d)', nAerP), nAerP; ...
          'FPR',    sprintf('Terrestrial UE-runs falsely flagged (of %d)', nNegP), nNegP};
for q = 1:2
    ax = nexttile(tl); hold(ax, 'on');
    for c = 1:numel(C.conditions)
        Q = Pt(Pt.Condition == string(C.conditions{c}), :);
        Q = sortrows(Q, 'WindowsObserved');
        lw = 1.2 + 0.8 * (c == 1);
        plot(ax, Q.WindowsObserved, Q.(panels{q, 1}) * panels{q, 3}, '-', 'LineWidth', lw, ...
             'Color', pal(c, :), 'DisplayName', C.labelOf(C.conditions{c}));
    end
    if q == 2
        nomFPR = Thr.NominalFPR(find(Thr.OperatingPoint == opLab, 1));
        yline(ax, nomFPR * nNegP, '--', 'Color', [0.7 0.2 0.2], ...
              'Label', sprintf('%s budget', opLab), 'FontSize', 8, 'HandleVisibility', 'off');
    else
        for lv = [halfLine mostLine]
            yline(ax, lv, ':', 'Color', [0.65 0.65 0.65], 'HandleVisibility', 'off');
        end
        legend(ax, 'Location', 'southeast', 'Box', 'off', 'FontSize', 8);
    end
    xlim(ax, [1 C.nWin]);
    xlabel(ax, 'Windows observed  (one window = one further second of observation)');
    ylabel(ax, panels{q, 2});
    title(ax, panels{q, 2});
    RPT.styleAxes(ax);
end
title(tl, sprintf('F8.7  D8.7 detection latency under evasion, %s, hold-out seeds %d to %d', ...
                  C.primaryName, min(C.holdoutSeeds), max(C.holdoutSeeds)), ...
      'FontWeight', 'bold');
RPT.saveFig(fig, fullfile(figDir, 'F8_7_latency_under_evasion.png'));
close(fig);

%% T8.11 How much time each evasion buys
%  Thresholds for "half" and "most" are expressed as counts of the aerial UE-runs
%  present, so the column headings do not smuggle a percentage back in.
nAer = max(Pt.AerialUERuns);
nNeg = max(Pt.TerrestrialUERuns);
halfN = ceil(0.50 * nAer);
mostN = ceil(0.80 * nAer);
tabRows = cell(numel(C.conditions), 1);
for c = 1:numel(C.conditions)
    Q = Pt(Pt.Condition == string(C.conditions{c}), :);
    Q = sortrows(Q, 'WindowsObserved');
    r = Q.Recall';
    tabRows{c} = {C.labelOf(C.conditions{c}), ...
        char(string(U.firstReach(r, Lgrid, 0.50))), ...
        char(string(U.firstReach(r, Lgrid, 0.80))), ...
        sprintf('%d of %d', round(r(1) * nAer), nAer), ...
        sprintf('%d of %d', round(r(end) * nAer), nAer), ...
        sprintf('%d of %d', round(Q.FPR(end) * nNeg), nNeg)};
end
T811 = cell2table(vertcat(tabRows{:}), 'VariableNames', ...
    {'Condition', ...
     sprintf('Windows_to_detect_%d_of_%d', halfN, nAer), ...
     sprintf('Windows_to_detect_%d_of_%d', mostN, nAer), ...
     'Detected_at_1_window', 'Detected_at_end', 'Falsely_flagged_at_end'});

RPT.tableFigure(T811, fullfile(figDir, 'T8_11_latency_under_evasion.png'), struct( ...
    'Title', sprintf('T8.11  D8.7 how much observation each evasion condition costs the operator, %s', ...
                     C.primaryName), ...
    'Highlight', string(T811.Condition) == "honest", ...
    'Note', ["";sprintf('Frozen %s threshold applied at every length; nothing is re-derived on hold-out data.', opLab); ...
             "The false positive rate at the end is reported because a shorter observation widens the null"; ...
             "distribution of the per-UE score, so a recall figure read alone would be flattering."; ...
             sprintf('Windows are 10 s long on a 1 s stride, capped at the %d-window truncation.', C.nWin)]));

%% Report
fprintf('\n%-26s %16s %16s %16s %18s\n', 'Condition', 'at 1 window', 'at end', ...
    sprintf('win to %d of %d', mostN, nAer), 'falsely flagged');
for c = 1:numel(C.conditions)
    fprintf('%-26s %16s %16s %16s %18s\n', T811.Condition{c}, ...
        T811.Detected_at_1_window{c}, T811.Detected_at_end{c}, ...
        T811.(sprintf('Windows_to_detect_%d_of_%d', mostN, nAer)){c}, ...
        T811.Falsely_flagged_at_end{c});
end
fprintf('\nCounts are aerial UE-runs detected, and terrestrial UE-runs falsely flagged.\n');

RPT.logSection(keyFile, 'D8.7  Detection latency under evasion', [""; ...
    sprintf('Primary model          : %s', C.primaryName); ...
    sprintf('Threshold              : frozen per-UE at %s, never re-derived on hold-out data', opLab); ...
    sprintf('Observation lengths    : 1 to %d windows', C.nWin); ...
    "Recall is reported beside the achieved false positive rate at every length, because truncation"; ...
    "widens the null distribution of the per-UE score and a recall figure read alone would flatter it."]);
RPT.logTable(keyFile, T811, 8);

fprintf('\nWrote results/latency_under_evasion.csv\n');
fprintf('Wrote figures/F8_7_latency_under_evasion.png and T8_11_latency_under_evasion.png\n');
