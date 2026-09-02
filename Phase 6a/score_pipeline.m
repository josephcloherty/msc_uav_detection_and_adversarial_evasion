function out = score_pipeline(pipelineFile, featuresIn, ueKey, winStart, opts)
%SCORE_PIPELINE Apply a frozen Phase 6 pipeline to new data.
%   out = score_pipeline(pipelineFile, featuresIn, ueKey, winStart) applies the frozen
%   pipeline in models/frozen_<key>.mat and returns a window score, a per-UE score and a
%   decision at each frozen threshold. This is the object the Phase 6 exit criterion
%   asks for and the only entry point Phase 7 should use.
%
%   featuresIn may be a table carrying at least the pipeline's predictor columns, or a
%   numeric matrix already in the pipeline's column order. A table is safer: the columns
%   are matched by name, so a change to the Phase 5 schema is caught rather than
%   silently shifting the predictors by one position.
%
%   ueKey and winStart identify which UE each row belongs to and where the row sits in
%   time. They are required because the per-UE score is a function of the ordered window
%   sequence, not of an unordered set.
%
%   opts.Level  'perUE' (default) or 'window', which decision is reported as the headline
%   opts.MaxWindows  truncate each UE to its first N windows, for a latency analysis
%
%   Returns a struct:
%     out.window   table of UE, WinStart, Score, Decision_1pct, Decision_5pct
%     out.perUE    table of UE, Score, nWindows, Decision_1pct, Decision_5pct
%     out.info     the frozen rule, thresholds and freeze date
%
%   Nothing here is fitted. Every constant, the imputation medians, the scaling, the
%   decision rule and both thresholds, is read from the frozen file. If this function
%   ever needs to compute one of them from the data it is given, the freeze has failed.

arguments
    pipelineFile (1, :) char
    featuresIn
    ueKey
    winStart double
    opts.Level (1, :) char {mustBeMember(opts.Level, {'perUE', 'window'})} = 'perUE'
    opts.MaxWindows double = Inf
end

U = phase6_util();
S = load(pipelineFile, 'pipeline');
p = S.pipeline;

%% Assemble the predictor matrix in the frozen column order
if istable(featuresIn)
    missing = setdiff(p.featureNames, featuresIn.Properties.VariableNames);
    assert(isempty(missing), 'score_pipeline:missingFeature', ...
        'The input is missing predictor(s) the frozen pipeline requires: %s', ...
        strjoin(missing, ', '));
    A = featuresIn{:, p.featureNames};
else
    assert(size(featuresIn, 2) == numel(p.featureNames), 'score_pipeline:widthMismatch', ...
        'Expected %d predictor columns in the frozen order, received %d.', ...
        numel(p.featureNames), size(featuresIn, 2));
    A = featuresIn;
end
assert(numel(ueKey) == size(A, 1) && numel(winStart) == size(A, 1), ...
    'score_pipeline:lengthMismatch', ...
    'ueKey and winStart must have one entry per row of the feature matrix.');

%% Apply the frozen preprocessing
A = U.imputeWith(A, p.imputeMedian);
if p.needsZ
    A = (A - p.mu) ./ p.sigma;
end

%% Window scores
%  The frozen file carries a handle to the scoring function that was in force when it
%  was frozen. A handle to a local function only resolves while its defining file is on
%  the path, so if it does not, the function is recovered from the registry by key and
%  the substitution is announced rather than made silently.
scoreFcn = p.scoreFcn;
try
    winScore = scoreFcn(p.model, A(1, :));
catch
    warning('score_pipeline:handleUnresolved', ...
        ['The frozen scoring handle for %s did not resolve, so it has been rebuilt from ' ...
         'phase6_models.m. Check that the registry has not changed since %s.'], ...
        p.name, string(p.freezeDate));
    reg = phase6_models(numel(p.featureNames));
    scoreFcn = reg(strcmp({reg.key}, p.key)).score;
end
winScore = scoreFcn(p.model, A);

%% Per-UE scores under the frozen decision rule
%  isPos is not known on unseen data, so a placeholder is passed; perUEScore uses it
%  only to carry the label through and it is discarded here.
Sue = U.perUEScore(winScore, ueKey, winStart, false(size(winScore)), p.rule, opts.MaxWindows);

%% Decisions at the frozen thresholds
out = struct();
out.window = table(string(ueKey(:)), winStart(:), winScore(:), ...
    winScore(:) >= p.windowThreshold(1), winScore(:) >= p.windowThreshold(2), ...
    'VariableNames', {'UE', 'WinStart_s', 'Score', 'Decision_1pctFPR', 'Decision_5pctFPR'});

out.perUE = table(Sue.UE, Sue.Score, Sue.nWindows, ...
    Sue.Score >= p.ueThreshold(1), Sue.Score >= p.ueThreshold(2), ...
    'VariableNames', {'UE', 'Score', 'nWindows', 'Decision_1pctFPR', 'Decision_5pctFPR'});

out.info = struct( ...
    'model',            p.name, ...
    'isPrimary',        p.isPrimary, ...
    'rule',             p.ruleLabel, ...
    'nominalFPR',       p.nominalFPR, ...
    'windowThreshold',  p.windowThreshold, ...
    'ueThreshold',      p.ueThreshold, ...
    'freezeDate',       p.freezeDate, ...
    'headlineLevel',    opts.Level);

end
