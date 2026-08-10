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
%   averaging the raw margin of a linear model is not the same operation as averaging a
%   probability. fitclinear with a logistic learner returns the linear predictor, so the
%   logistic link is applied here to recover the probability exactly.

if nargin < 1 || isempty(numPredictors)
    error('phase6_models:noPredictorCount', ...
        'Pass the predictor count so the forest can size NumVariablesToSample.');
end
numVars = max(1, round(sqrt(numPredictors)));

M = struct('name', {}, 'key', {}, 'needsZ', {}, 'fit', {}, 'score', {});

%% K-nearest neighbours
%  Distance-based, so 'Standardize' rescales using training statistics only. With
%  k = 10 the posterior takes eleven distinct values, which makes the ROC coarse and
%  is worth remembering when reading its recall at a 1 per cent false alarm rate.
M(1).name   = 'KNN';
M(1).key    = 'knn';
M(1).needsZ = false;
M(1).fit    = @(X, Y) fitcknn(X, Y, 'NumNeighbors', 10, ...
                              'Distance', 'euclidean', 'Standardize', true);
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
M(4).name   = 'Logistic Regression';
M(4).key    = 'logistic_regression';
M(4).needsZ = true;
M(4).fit    = @(X, Y) fitclinear(X, Y, 'Learner', 'logistic');
M(4).score  = @logisticScore;

%% Discriminant analysis
%  pseudoLinear tolerates the near-singular covariance that collinear radio features
%  produce; plain linear discriminant analysis fails outright on them.
M(5).name   = 'Discriminant Analysis';
M(5).key    = 'discriminant_analysis';
M(5).needsZ = false;
M(5).fit    = @(X, Y) fitcdiscr(X, Y, 'DiscrimType', 'pseudoLinear');
M(5).score  = @posteriorScore;

end


%% ---- families whose second predict output is already a posterior ----
function p = posteriorScore(mdl, X)
    [~, s] = predict(mdl, X);
    p = s(:, mdl.ClassNames == 'Aerial');
end


%% ---- fitclinear returns the linear predictor, so apply the logistic link ----
%  Monotone in the raw score, so the ROC is unchanged, but the value is now a
%  probability and can be averaged across a UE's windows on the same footing as the
%  other four families.
function p = logisticScore(mdl, X)
    [~, s] = predict(mdl, X);
    raw = s(:, mdl.ClassNames == 'Aerial');
    p = 1 ./ (1 + exp(-raw));
end
