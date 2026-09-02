function V = p8_util()
%P8_UTIL Shared inference and reporting helpers for Phase 8.
%   V = p8_util() returns a struct of function handles, following the Phase 6 pattern:
%   MATLAB local functions are not visible outside their defining file, so exporting
%   handles is what lets every stage share one definition of each quantity. The stages
%   themselves are plain scripts with no local functions, so each can be run on its own
%   from the editor without any question about how a local function would resolve.
%
%   V.clusterBoot(runKey, stat, nBoot, seed, level)  run-level cluster bootstrap
%   V.metricsAt(score, isPos, thr)        TPR, FPR, precision, F1 and counts at a threshold
%   V.aucOf(isPos, score)                 scalar AUC, NaN when a class is absent
%   V.tprAt / V.fprAt (score, isPos, thr) single scalars, for bootstrap statistics
%   V.meanIf(v, keep)                     mean of a subset, NaN when the subset is empty
%   V.logit(p) / V.invlogit(z)            log odds, clipped away from the asymptotes
%   V.signRank(d)                         two-sided Wilcoxon signed-rank, NaN-safe
%   V.fmtCI(est, lo, hi)                  printable point estimate with interval
%   V.cpLo(k, n) / V.cpHi(k, n)           exact Clopper-Pearson bounds on a proportion
%   V.fmtCount(k, n)                      "22 of 25"
%   V.fmtCountCI(k, n)                    "22 of 25 [19 to 25]", bounds as UE-runs
%   V.styleAxes(ax)                       one figure style for every Phase 8 plot
%   V.palette()                           condition colours, consistent across figures
%   V.saveFig(fig, file)                  write a figure at publication resolution
%
%   The scalar wrappers exist so that the deliverable stages can build bootstrap
%   statistics as anonymous functions and stay free of local functions themselves, which
%   is what keeps them runnable as plain scripts.
%
%   Phase 8 reports counts of UE-runs rather than rates. The hold-out carries twenty-five
%   aerial and one hundred and twenty terrestrial UE-runs, so one aerial UE-run is four
%   points of recall and one terrestrial UE-run is 0.833 points of false positive rate. A
%   percentage quoted to three figures on that sample implies a precision the sample does
%   not have, and it obscures how few units the conclusion rests on. The count is the
%   measurement; a rate is a derived quantity and is kept only where the quantity is
%   inherently a rate, as in the base-rate deliverable.

V.clusterBoot = @clusterBoot;
V.metricsAt   = @metricsAt;
V.aucOf       = @aucOf;
V.tprAt       = @tprAt;
V.fprAt       = @fprAt;
V.meanIf      = @meanIf;
V.logit       = @logit;
V.invlogit    = @invlogit;
V.signRank    = @signRank;
V.fmtCI       = @fmtCI;
V.fmtP        = @fmtP;
V.cpLo        = @cpLo;
V.cpHi        = @cpHi;
V.fmtCount    = @fmtCount;
V.fmtCountCI  = @fmtCountCI;
V.styleAxes   = @styleAxes;
V.palette     = @palette;
V.saveFig     = @saveFig;
end


%% ---- exact binomial bounds, Clopper-Pearson ----
%  Obtained by inverting the binomial test rather than by assuming the estimate is
%  normally distributed. That matters at the boundary, which is where several Phase 8
%  results sit: at twenty-five of twenty-five the sample variance is exactly zero, so a
%  bootstrap resamples twenty-five successes every time and returns a point rather than
%  an interval, reporting a certainty twenty-five units cannot support. Clopper-Pearson
%  still returns a lower bound because it never looks at the spread; it asks instead
%  which true rates could plausibly have produced the observed count.
function lo = cpLo(k, n, alpha)
    if nargin < 3, alpha = 0.05; end
    if n == 0, lo = NaN; return; end
    if k <= 0, lo = 0; return; end
    lo = betainv(alpha / 2, k, n - k + 1);
end

function hi = cpHi(k, n, alpha)
    if nargin < 3, alpha = 0.05; end
    if n == 0, hi = NaN; return; end
    if k >= n, hi = 1; return; end
    hi = betainv(1 - alpha / 2, k + 1, n - k);
end


%% ---- counts, printed as counts ----
%  fmtCountCI converts the Clopper-Pearson bounds back into UE-runs so that a table never
%  mixes scales. The bounds are floored and ceiled outwards, which is the conservative
%  direction: an interval quoted in whole units should not exclude a count the data is
%  consistent with.
function s = fmtCount(k, n)
    s = sprintf('%d of %d', k, n);
end

function s = fmtCountCI(k, n, alpha)
    if nargin < 3, alpha = 0.05; end
    if n == 0, s = 'no units'; return; end
    lo = floor(cpLo(k, n, alpha) * n);
    hi = ceil(cpHi(k, n, alpha) * n);
    s = sprintf('%d of %d [%d to %d]', k, n, lo, hi);
end


%% ---- run-level cluster bootstrap ----
%  Whole runs are resampled, not rows. UE-runs inside one simulation run share a
%  scenario, a seed, a channel realisation and each other's interference, so they are not
%  independent draws; resampling rows would treat them as though they were and would
%  report an interval several times narrower than the evidence supports.
%
%  stat is a function of a row index vector, so the caller decides what is being
%  estimated and this function only decides which rows it sees. A resample that leaves
%  the statistic undefined, most often by containing no aerial UE, yields NaN for that
%  replicate and is dropped from the percentile calculation rather than being replaced by
%  a fallback value, and the count of usable replicates is returned so a badly behaved
%  interval is visible rather than implied.
function [est, lo, hi, boots, nOK] = clusterBoot(runKey, stat, nBoot, seed, level)
    if nargin < 5 || isempty(level), level = 0.95; end
    runKey = string(runKey(:));
    [runs, ~, g] = unique(runKey);
    nR = numel(runs);
    idxByRun = arrayfun(@(r) find(g == r), (1:nR)', 'UniformOutput', false);

    est = stat((1:numel(runKey))');

    rs = RandStream('mt19937ar', 'Seed', seed);
    boots = nan(nBoot, 1);
    for b = 1:nBoot
        pick = randi(rs, nR, nR, 1);
        idx  = vertcat(idxByRun{pick});
        try
            boots(b) = stat(idx);
        catch
            boots(b) = NaN;
        end
    end

    ok  = boots(~isnan(boots));
    nOK = numel(ok);
    if nOK < 20
        lo = NaN;  hi = NaN;
        return;
    end
    a  = (1 - level) / 2;
    lo = prctile(ok, 100 * a);
    hi = prctile(ok, 100 * (1 - a));
end


%% ---- point metrics at a fixed threshold ----
%  Flags when score >= thr, matching the convention in phase6_util.pickThreshold. The
%  frozen threshold is applied exactly as frozen; nothing here re-derives an operating
%  point, since a threshold refitted on hold-out data would make the false positive rate
%  a fitted quantity rather than a measured one.
function m = metricsAt(score, isPos, thr)
    score = score(:);  isPos = logical(isPos(:));
    flag  = score >= thr;

    m = struct();
    m.nPos = sum(isPos);
    m.nNeg = sum(~isPos);
    m.TP   = sum(flag &  isPos);
    m.FP   = sum(flag & ~isPos);
    m.FN   = sum(~flag &  isPos);
    m.TN   = sum(~flag & ~isPos);

    if m.nPos > 0, m.TPR = m.TP / m.nPos; else, m.TPR = NaN; end
    if m.nNeg > 0, m.FPR = m.FP / m.nNeg; else, m.FPR = NaN; end
    if (m.TP + m.FP) > 0, m.Precision = m.TP / (m.TP + m.FP); else, m.Precision = NaN; end
    if isnan(m.Precision) || isnan(m.TPR) || (m.Precision + m.TPR) == 0
        m.F1 = NaN;
    else
        m.F1 = 2 * m.Precision * m.TPR / (m.Precision + m.TPR);
    end
end


%% ---- scalar wrappers, for use as bootstrap statistics ----
%  Each returns NaN rather than erroring when the input cannot support the quantity, most
%  often a resample that happens to contain no aerial UE. clusterBoot drops those
%  replicates and reports how many survived, so a degenerate resample weakens the interval
%  visibly instead of biasing it silently.
function a = aucOf(isPos, score)
    isPos = logical(isPos(:));
    if all(isPos) || ~any(isPos)
        a = NaN;
        return;
    end
    [~, ~, ~, a] = perfcurve(double(isPos), score(:), 1);
end

function r = tprAt(score, isPos, thr)
    isPos = logical(isPos(:));
    if ~any(isPos), r = NaN; else, r = mean(score(isPos) >= thr); end
end

function r = fprAt(score, isPos, thr)
    isPos = logical(isPos(:));
    if all(isPos), r = NaN; else, r = mean(score(~isPos) >= thr); end
end

function v = meanIf(x, keep)
    x = x(logical(keep));
    x = x(~isnan(x));
    if isempty(x), v = NaN; else, v = mean(x); end
end


%% ---- log odds, clipped ----
%  Per-UE scores are mean posteriors and can sit at 0 or 1 exactly, where the logit is
%  infinite. Clipping at eps keeps the transform finite without materially moving any
%  interior value. The clip is deliberately tighter than any observed score resolution,
%  so it changes only the saturated cases it exists to handle.
function z = logit(p)
    e = 1e-6;
    p = min(max(p, e), 1 - e);
    z = log(p ./ (1 - p));
end

function p = invlogit(z)
    p = 1 ./ (1 + exp(-z));
end


%% ---- two-sided Wilcoxon signed-rank, NaN-safe ----
%  Returns NaN rather than erroring when the paired differences carry no information,
%  which happens whenever every run gives the same answer. A NaN in the results table is
%  a statement that the test could not be run; a fabricated p-value is not.
function [p, n] = signRank(d)
    d = d(:);
    d = d(~isnan(d));
    n = numel(d);
    if n < 2 || all(d == 0)
        p = NaN;
        return;
    end
    p = signrank(d);
end


%% ---- printable point estimate with interval ----
function s = fmtCI(est, lo, hi, dp)
    if nargin < 4, dp = 3; end
    f = sprintf('%%.%df', dp);
    if isnan(lo) || isnan(hi)
        s = sprintf([f ' [CI unavailable]'], est);
    else
        s = sprintf([f ' [' f ', ' f ']'], est, lo, hi);
    end
end


%% ---- printable p-value ----
%  "not computable" rather than a number when the test could not be run, so a table cell
%  never implies a test that did not happen.
function s = fmtP(p)
    if isnan(p)
        s = 'not computable';
    elseif p < 0.001
        s = '<0.001';
    else
        s = sprintf('%.3f', p);
    end
end


%% ---- one figure style for every Phase 8 plot ----
function styleAxes(ax)
    % Delegated so that Phase 6, 7 and 8 figures share one definition of "styled",
    % including the white background and black text a printed report needs.
    R = report_util();
    R.styleAxes(ax);
end


%% ---- condition colours, consistent across every figure ----
%  Honest is grey because it is the reference and not a treatment. Returning a containers
%  map keyed by condition name means a condition added to the dataset gets a colour
%  without any figure script being edited.
function m = palette(conditions)
    base = [0.35 0.35 0.35;      % honest
            0.00 0.45 0.70;      % first evasive condition
            0.85 0.37 0.01;      % second
            0.46 0.16 0.51;      % third
            0.10 0.60 0.35];     % fourth
    if nargin < 1 || isempty(conditions)
        m = base;
        return;
    end
    m = containers.Map();
    for k = 1:numel(conditions)
        m(conditions{k}) = base(min(k, size(base, 1)), :);
    end
end


%% ---- write a figure at publication resolution ----
function saveFig(fig, file)
    % Delegated so the figures this file writes get the same light-theme treatment as
    % every other report figure. MATLAB's dark theme otherwise exports a black axes
    % background and pale grey text, which is unreadable on paper.
    R = report_util();
    R.saveFig(fig, file);
end
