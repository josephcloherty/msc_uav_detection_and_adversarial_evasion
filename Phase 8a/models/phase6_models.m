function M = phase6_models(numPredictors)
%PHASE6_MODELS Single definition of the five Phase 6 classifier families.
%   M = phase6_models(numPredictors) returns a struct array, one entry per family,
%   carrying everything the cross-validation, freezing and scoring scripts need:
%
%     .name    label used in every results table
%     .key     filename-safe short name
%     .needsZ  true when the fit is not invariant to predictor scale
%     .fit     @(X, Y) -> trained model, X a numeric matrix
%     .score   @(model, X) -> posterior probability of the Aerial class, in [0, 1]
%
%   numPredictors sets the number of variables each forest tree samples per split and
%   must be the predictor count of the matrix the model will actually see.
%
%   Every family is defined once, here. The previous layout repeated the five model
%   definitions across train/*.m and run_cv.m, which meant a hyperparameter changed in
%   one place and not the other would have produced cross-validation evidence that did
%   not describe the model eventually frozen.
%
%   .score returns a posterior on a common [0, 1] scale for all five, not each family's
%   native score. This matters because D6.3 averages scores across a UE's windows, and
%   averaging an uncalibrated transform of a score is not the same operation as
%   averaging a probability.

if nargin < 1 || isempty(numPredictors)
    error('phase6_models:noPredictorCount', ...
        'Pass the predictor count so the forest can size NumVariablesToSample.');
end
numVars = max(1, round(sqrt(numPredictors)));

M = struct('name', {}, 'key', {}, 'needsZ', {}, 'fit', {}, 'score', {});

%% K-nearest neighbours
%  Distance-based, so 'Standardize' rescales using training statistics only.
%
%  The neighbour count is set by a measurement requirement rather than by accuracy. An
%  unweighted k-neighbour vote can only take k+1 distinct values, so the ROC has k+1
%  points; at k = 10 the first execution found that the highest available threshold in
%  one fold already sat at a false alarm rate of 1.083 per cent, leaving no operating
%  point at or below the 1 per cent target and making recall there unmeasurable rather
%  than merely poor. Fifty neighbours with inverse distance weighting gives a score that
%  is effectively continuous, so an operating point exists wherever it is asked for. The
%  weighting also restores the local sensitivity that a larger neighbourhood would
%  otherwise cost, since near neighbours dominate the vote.
M(1).name   = 'KNN';
M(1).key    = 'knn';
M(1).needsZ = false;
M(1).fit    = @(X, Y) fitcknn(X, Y, 'NumNeighbors', 50, 'Distance', 'euclidean', ...
                              'DistanceWeight', 'inverse', 'Standardize', true);
M(1).score  = @posteriorScore;

%% Random forest
%  Each of the 100 trees sees a bootstrap sample and considers sqrt(p) predictors per
%  split. NumVariablesToSample requires an explicit integer.
M(2).name   = 'Random Forest';
M(2).key    = 'random_forest';
M(2).needsZ = false;
M(2).fit    = @(X, Y) fitcensemble(X, Y, 'Method', 'Bag', 'NumLearningCycles', 100, ...
                        'Learners', templateTree('NumVariablesToSample', numVars, ...
                                                 'Reproducible', true));
M(2).score  = @posteriorScore;

%% Single decision tree
%  MinLeafSize 20 stops leaves being formed from a handful of near-duplicate windows;
%  a 1 s stride on a 10 s window makes neighbouring rows about 90 per cent identical.
M(3).name   = 'Decision Tree';
M(3).key    = 'decision_tree';
M(3).needsZ = false;
M(3).fit    = @(X, Y) fitctree(X, Y, 'MaxNumSplits', 100, 'MinLeafSize', 20);
M(3).score  = @posteriorScore;

%% Logistic regression
%  fitclinear applies a ridge penalty, which is not invariant to predictor scale, and
%  the predictors span standard deviations over several orders of magnitude. Without
%  standardisation the penalty falls almost entirely on the decibel-scale features.
%
%  The second output of predict is used directly, as for the other families. An earlier
%  version applied a logistic link to it on the assumption that a logistic learner
%  returns the linear predictor. It does not: for this learner the value is already a
%  posterior, and applying the link a second time compressed every score in the
%  development set into the range 0.5001 to 0.7310. The ranking survived, the link being
%  monotone, so the AUC and the recall at fixed false alarm rates were unaffected, but
%  the value was no longer a probability, every window fell above 0.5, and any figure
%  read at that threshold was meaningless. The check below now catches a repeat.
M(4).name   = 'Logistic Regression';
M(4).key    = 'logistic_regression';
M(4).needsZ = true;
M(4).fit    = @(X, Y) fitclinear(X, Y, 'Learner', 'logistic');
M(4).score  = @posteriorScore;

%% Discriminant analysis
%  pseudoLinear tolerates the near-singular covariance that collinear radio features
%  produce; plain linear discriminant analysis fails outright on them.
M(5).name   = 'Discriminant Analysis';
M(5).key    = 'discriminant_analysis';
M(5).needsZ = false;
M(5).fit    = @(X, Y) fitcdiscr(X, Y, 'DiscrimType', 'pseudoLinear');
M(5).score  = @posteriorScore;

end


%% ---- posterior probability of the Aerial class ----
%  All five families return a posterior in the second output of predict. The range is
%  checked rather than assumed, because a score that is monotone in the truth but not on
%  the probability scale passes every rank-based metric silently and only shows itself
%  when a fixed threshold is applied or when scores are averaged across a UE's windows.
function p = posteriorScore(mdl, X)
    [~, s] = predict(mdl, X);
    p = s(:, mdl.ClassNames == 'Aerial');
    assert(all(p >= -1e-9 & p <= 1 + 1e-9), 'phase6_models:notAPosterior', ...
        ['Scores from %s fall outside [0, 1] (observed %.4f to %.4f), so they are not ' ...
         'posteriors. Fix the scoring function before using any threshold or per-UE ' ...
         'average.'], class(mdl), min(p), max(p));
    p = min(max(p, 0), 1);
end
