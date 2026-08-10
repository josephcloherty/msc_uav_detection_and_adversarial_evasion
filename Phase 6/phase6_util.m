function U = phase6_util()
%PHASE6_UTIL Shared metric and decision-rule helpers for Phase 6.
%   U = phase6_util() returns a struct of function handles. MATLAB local functions
%   are not visible outside the file that defines them, so exporting them as handles
%   is what lets every Phase 6 script share one definition of each metric. A metric
%   computed two slightly different ways in two scripts is the most likely source of
%   an inconsistency that survives review, so there is exactly one definition here.
%
%   U.imputeWith(A, med)                  replace NaNs with supplied column values
%   U.rocCurve(labels, s, posClass)       deduplicated ROC, FPR strictly ascending
%   U.recallAtFPR(x, y, target)           highest TPR at or below a nominal FPR
%   U.partialAUC(x, y, xmax)              [raw, normalised] AUC over FPR <= xmax
%   U.pickThreshold(s, isPos, target)     operating point at a nominal FPR
%   U.perUEScore(s, ueKey, ord, isPos, rule, maxWin)   collapse windows to one UE score
%   U.ruleLabel(rule)                     printable name of a decision rule
%   U.foldAssign(runScen, runPos, runTot, K)           grouped stratified fold labels
%   U.rangeText(v)                        print a seed list as a range when contiguous
%   U.firstReach(r, grid, level)          first grid point at which a curve reaches level
%   U.writeLiteratureTemplate(file, names) editable literature and manipulability table
%
%   The reporting helpers live here rather than as local functions in the stage scripts
%   so that every stage is a plain script. run_phase6.m calls the stages through a
%   function wrapper, and keeping them free of local functions removes any question
%   about how those would resolve when the script is run from inside another function.

U.imputeWith    = @imputeWith;
U.rocCurve      = @rocCurve;
U.recallAtFPR   = @recallAtFPR;
U.partialAUC    = @partialAUC;
U.pickThreshold = @pickThreshold;
U.perUEScore    = @perUEScore;
U.ruleLabel     = @ruleLabel;
U.foldAssign    = @foldAssign;
U.rangeText     = @rangeText;
U.firstReach    = @firstReach;
U.writeLiteratureTemplate = @writeLiteratureTemplate;
end


%% ---- replace NaNs with supplied column values ----
function A = imputeWith(A, colValues)
    for j = 1:size(A, 2)
        A(isnan(A(:, j)), j) = colValues(j);
    end
end


%% ---- ROC with one point per distinct false positive rate ----
%  perfcurve emits several points at the same FPR when scores tie. Keeping the last
%  of each group takes the upper envelope, which is the operating point actually
%  available at that false alarm rate, and makes the curve safe to interpolate.
function [x, y, auc] = rocCurve(labels, scores, posClass)
    [x, y, ~, auc] = perfcurve(labels, scores, posClass);
    [x, iLast] = unique(x, 'last');
    y = y(iLast);
end


%% ---- highest recall available at or below a nominal false positive rate ----
function r = recallAtFPR(x, y, target)
    k = find(x <= target, 1, 'last');
    if isempty(k)
        r = 0;
    else
        r = y(k);
    end
end


%% ---- partial AUC over the low false alarm region ----
%  The full AUC integrates over false alarm rates no operator would ever run at.
%  pa is the raw area over FPR in [0, xmax]; paNorm divides by xmax so it reads as
%  the mean recall across that region and is comparable against the full AUC scale.
function [pa, paNorm] = partialAUC(x, y, xmax)
    keep = x <= xmax;
    xs = x(keep);  ys = y(keep);
    if isempty(xs)
        pa = 0;  paNorm = 0;  return;
    end
    if xs(1) > 0                                   % anchor the left edge at FPR 0
        xs = [0; xs];  ys = [ys(1); ys];
    end
    if xs(end) < xmax                              % close the right edge at xmax
        yEnd = interp1(x, y, xmax, 'linear', ys(end));
        xs = [xs; xmax];  ys = [ys; yEnd];
    end
    pa     = trapz(xs, ys);
    paNorm = pa / xmax;
end


%% ---- operating point at a nominal false positive rate ----
%  Flags when score >= t. Returns the smallest such t whose false positive rate does
%  not exceed the target, so the recall reported is the largest available without
%  breaching the nominal rate. The achieved rate is returned alongside because with a
%  finite sample it is almost never equal to the nominal one, and the write-up has to
%  quote what was achieved rather than what was asked for.
function [t, achFPR, recall, nFP, nNeg] = pickThreshold(scores, isPos, targetFPR)
    isPos = logical(isPos(:));
    scores = scores(:);
    neg  = sort(scores(~isPos));
    pos  = sort(scores(isPos));
    nNeg = numel(neg);  nPos = numel(pos);
    assert(nNeg > 0 && nPos > 0, 'phase6_util:oneClass', ...
        'pickThreshold needs both classes present.');

    cand  = unique(scores);                        % ascending candidate thresholds
    edges = [-Inf; cand(:); Inf];
    negBelow = cumsum(histcounts(neg, edges));     % negBelow(i) = #neg strictly < cand(i)
    posBelow = cumsum(histcounts(pos, edges));
    fprAll = (nNeg - negBelow(1:numel(cand))') / nNeg;
    tprAll = (nPos - posBelow(1:numel(cand))') / nPos;

    k = find(fprAll <= targetFPR, 1, 'first');
    if isempty(k)
        % Every candidate breaches the target, which happens only when the top scores
        % are tied across classes. Flag nothing rather than silently overshooting.
        t = Inf;  achFPR = 0;  recall = 0;  nFP = 0;
    else
        t = cand(k);  achFPR = fprAll(k);  recall = tprAll(k);
        nFP = round(achFPR * nNeg);
    end
end


%% ---- collapse a UE's window scores into a single per-UE score ----
%  rule.type is 'mean' or 'mofn'. The M-of-N score is the maximum, over every block of
%  N consecutive windows, of the M-th largest score in that block. Thresholding that
%  value at t is exactly the statement "at some point M of N consecutive windows
%  exceeded t", so a persistence rule and a continuous score are the same object and
%  the rule can be given an ROC rather than a single operating point.
%  maxWin truncates each UE to its first maxWin windows, which is what makes the
%  detection latency curve a question about observation length rather than about
%  which UEs happen to have long trajectories.
function S = perUEScore(scores, ueKey, ord, isPos, rule, maxWin)
    if nargin < 6 || isempty(maxWin), maxWin = Inf; end
    ueKey = string(ueKey(:));
    scores = scores(:);  ord = ord(:);  isPos = logical(isPos(:));

    [ueList, ~, g] = unique(ueKey, 'stable');
    nUE = numel(ueList);
    ueScore = nan(nUE, 1);
    uePos   = false(nUE, 1);
    nWin    = zeros(nUE, 1);

    for i = 1:nUE
        m = (g == i);
        s = scores(m);
        [~, byTime] = sort(ord(m));
        s = s(byTime);
        if numel(s) > maxWin, s = s(1:maxWin); end
        nWin(i)    = numel(s);
        uePos(i)   = any(isPos(m));
        ueScore(i) = collapse(s, rule);
    end

    S = table(ueList, ueScore, uePos, nWin, ...
        'VariableNames', {'UE', 'Score', 'IsPos', 'nWindows'});
end


function v = collapse(s, rule)
    switch lower(string(rule.type))
        case "mean"
            v = mean(s);
        case "mofn"
            % A UE observed for fewer than N windows is judged on what it has, with M
            % reduced in step, so short trajectories are neither dropped nor advantaged.
            N = min(rule.N, numel(s));
            M = min(rule.M, N);
            v = -Inf;
            for b = 1:(numel(s) - N + 1)
                blk = sort(s(b:b+N-1), 'descend');
                v = max(v, blk(M));
            end
        otherwise
            error('phase6_util:badRule', 'Unknown decision rule type "%s".', rule.type);
    end
end


%% ---- printable name of a decision rule ----
function s = ruleLabel(rule)
    switch lower(string(rule.type))
        case "mean",  s = 'mean posterior';
        case "mofn",  s = sprintf('%d-of-%d persistence', rule.M, rule.N);
        otherwise,    s = char(rule.type);
    end
end


%% ---- grouped stratified fold assignment at run level ----
%  Whole runs go to folds, so no seed contributes rows to both sides of a fold. Within
%  each scenario the runs are ordered by aerial prevalence and dealt out serpentine
%  (1..K then K..1), which balances both scenario mix and class prevalence across folds
%  without any randomness, so the same runs land in the same fold on every execution.
%  Prevalence varies from one aerial UE per run to six, so ignoring it would leave the
%  folds materially unequal in positive rate.
function foldOfRun = foldAssign(runScen, runPos, runTot, K)
    runScen = string(runScen(:));
    prevalence = runPos(:) ./ max(runTot(:), 1);
    foldOfRun = zeros(numel(runScen), 1);

    for s = unique(runScen)'
        idx = find(runScen == s);
        [~, byPrev] = sort(prevalence(idx), 'ascend');
        idx = idx(byPrev);
        pattern = zeros(numel(idx), 1);
        for p = 1:numel(idx)
            pass = ceil(p / K);
            slot = p - (pass - 1) * K;
            if mod(pass, 2) == 1
                pattern(p) = slot;
            else
                pattern(p) = K - slot + 1;
            end
        end
        foldOfRun(idx) = pattern;
    end
end


%% ---- print a seed list as a range when it is contiguous ----
function s = rangeText(v)
    if numel(v) > 1 && isequal(v, min(v):max(v))
        s = sprintf('%d:%d (%d seeds)', min(v), max(v), numel(v));
    else
        s = sprintf('%s (%d seeds)', mat2str(v), numel(v));
    end
end


%% ---- first grid point at which a curve reaches a level ----
function s = firstReach(r, grid, level)
    k = find(r >= level, 1, 'first');
    if isempty(k)
        s = 'not reached';
    else
        s = sprintf('%d', grid(k));
    end
end


%% ---- editable literature expectation and manipulability table ----
%  Feature blocks and manipulability are filled with defaults so the file is usable
%  immediately; the literature expectation and source columns are deliberately left as
%  REVIEW, because attributing a claim to Ryden et al. or to a patent is a reading of
%  those sources and not something a script can do on their behalf.
%
%  The manipulability defaults follow one principle: a quantity the network measures for
%  itself is hard for a UE to falsify, a quantity the UE reports is easier, and a
%  quantity generated by the application running on the UE is entirely under its control.
%  They are defaults to be confirmed, not findings.
function writeLiteratureTemplate(litFile, featureNames)
    blocks = { ...
        '^servSINR',                     'Serving cell SINR',      'Low'
        '^(nbrSINR|sinrSpread|numAboveThr|nbrWithin|top3Nbr|servMinusBestNbr)', ...
                                         'Neighbour geometry',     'Low'
        '^(cqi|mcs|ulMcsCtx|spectralEff)', 'Channel quality',      'Medium'
        '^(ri_|rankOne|layers)',         'MIMO rank',              'Medium'
        '^retxRate',                     'Retransmission',         'Low'
        '^(hoCount|meanInterHO|hoRate|pingPong|timeSinceHO|distinctServCells|servCellEntropy)', ...
                                         'Handover and mobility',  'Low'
        '^ta_',                          'Timing advance',         'Low'
        '^(ulVol|dlVol|ulThr|dlThr|thr_mean|grantRate|prb|dlulAsym|traffic)', ...
                                         'Traffic and scheduling', 'High' };

    n = numel(featureNames);
    blk = strings(n, 1);  man = strings(n, 1);
    for i = 1:n
        blk(i) = "Unclassified";  man(i) = "REVIEW";
        for b = 1:size(blocks, 1)
            if ~isempty(regexp(featureNames{i}, blocks{b, 1}, 'once'))
                blk(i) = string(blocks{b, 2});
                man(i) = string(blocks{b, 3});
                break;
            end
        end
    end

    Tlit = table(string(featureNames(:)), blk, ...
        repmat("REVIEW", n, 1), repmat("REVIEW", n, 1), man, ...
        'VariableNames', {'Feature', 'FeatureBlock', ...
        'LiteratureExpectation', 'Source', 'Manipulability'});
    writetable(Tlit, litFile);
end
