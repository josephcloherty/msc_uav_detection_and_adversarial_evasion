function phase6_AerialCull(side, keepFraction)
%phase6_AerialCull Thin the aerial UEs in the training or test split.
%   phase6_AerialCull('train', 0.6) keeps 60 per cent of the aerial UEs in the
%   training set and drops every window belonging to the other 40 per cent.
%   phase6_AerialCull('test', 0.1) keeps 10 per cent of the aerial UEs in the
%   test set, a 90 per cent cull.
%   phase6_AerialCull('reset') restores both sides to the full prepared data.
%   phase6_AerialCull('status') reports the cull currently in force.
%
%   Whole UE trajectories are dropped rather than individual rows. Windows use a
%   1 s stride on a 10 s window, so rows from one UE are about 90 per cent
%   identical; thinning rows would remove overlap rather than information, and
%   the aerial UEs are the limiting independent unit in this dataset.
%
%   Terrestrial rows are never touched, and the aerial UEs that survive keep all
%   of their windows, so the class prior changes but nothing else does.
%
%   The full split is kept in prepared_data/phase6_data_full.mat and every call
%   culls from that copy, so repeated calls do not compound. The two sides are
%   tracked separately, so culling one leaves the other as it was. Rerunning
%   prepare_data.m clears any cull.
%
%   Retrain after calling this: run train_all.m, then test_all.m.

%% Validate the arguments
    if nargin < 1, side = 'status'; end
    side = lower(string(side));
    assert(ismember(side, ["train", "test", "reset", "status"]), ...
        'phase6_AerialCull:badSide', ...
        'First argument must be ''train'', ''test'', ''reset'' or ''status''.');

    if ismember(side, ["train", "test"])
        assert(nargin == 2 && isnumeric(keepFraction) && isscalar(keepFraction), ...
            'phase6_AerialCull:badFraction', ...
            'Second argument must be a scalar keep fraction, e.g. 0.6 for a 40%% cull.');
        assert(keepFraction > 0 && keepFraction <= 1, 'phase6_AerialCull:badFraction', ...
            'Keep fraction must be greater than 0 and at most 1; 0 would leave one class.');
    end

%% Locate the prepared data and its untouched master copy
    root = fileparts(which('prepare_data'));
    assert(~isempty(root), 'phase6_AerialCull:pathNotSet', ...
        'Set the current folder to Phase 6 before calling this function.');
    workFile = fullfile(root, 'prepared_data', 'phase6_data.mat');
    fullFile = fullfile(root, 'prepared_data', 'phase6_data_full.mat');
    assert(isfile(workFile), 'phase6_AerialCull:noData', ...
        'prepared_data/phase6_data.mat not found; run prepare_data.m first.');

    % List the stored variables without loading them, so an absent one is not a warning.
    vars = who('-file', workFile);
    assert(ismember('ueKeyTrain', vars), 'phase6_AerialCull:noUeKey', ...
        ['prepared_data/phase6_data.mat holds no UE key, so it was written before ' ...
         'this function existed; rerun prepare_data.m.']);

    % A working file carrying no cull record is untouched prepare_data.m output,
    % so it becomes the master. This makes rerunning prepare_data.m clear the cull.
    if ~ismember('cullKeepTrain', vars)
        copyfile(workFile, fullFile);
        keepTrain = 1;  keepTest = 1;
    else
        assert(isfile(fullFile), 'phase6_AerialCull:noMaster', ...
            ['prepared_data/phase6_data.mat is culled but the full copy is missing; ' ...
             'rerun prepare_data.m.']);
        stamp     = load(workFile, 'cullKeepTrain', 'cullKeepTest');
        keepTrain = stamp.cullKeepTrain;
        keepTest  = stamp.cullKeepTest;
    end

%% Handle the reporting and reset cases
    if side == "status"
        fprintf('Aerial cull in force: train keeps %.0f%%, test keeps %.0f%%.\n', ...
            100 * keepTrain, 100 * keepTest);
        return
    end
    if side == "reset"
        copyfile(fullFile, workFile);
        fprintf('Reset: both sides restored to the full prepared data.\n');
        return
    end

%% Record the requested fraction, leaving the other side as it was
    if side == "train", keepTrain = keepFraction; else, keepTest = keepFraction; end

%% Rebuild both sides from the master copy
    S = load(fullFile);
    [S.Xtrain, S.Ytrain, S.ueKeyTrain, repTrain] = ...
        cullSide(S.Xtrain, S.Ytrain, S.ueKeyTrain, keepTrain);
    [S.Xtest,  S.Ytest,  S.ueKeyTest,  repTest]  = ...
        cullSide(S.Xtest,  S.Ytest,  S.ueKeyTest,  keepTest);

    S.cullKeepTrain = keepTrain;
    S.cullKeepTest  = keepTest;
    save(workFile, '-struct', 'S');

%% Report both sides
    fprintf('\n%-7s %-9s %-9s %-9s %-9s %s\n', ...
        'Side', 'Keep', 'AerialUE', 'AerialRow', 'TotalRow', 'Aerial share');
    printSide('Train', keepTrain, repTrain);
    printSide('Test',  keepTest,  repTest);
    fprintf('\nRetrain with train_all.m, then test_all.m.\n');
end

%% ---- drop all windows of the aerial UEs that are not selected ----
function [X, Y, ueKey, rep] = cullSide(X, Y, ueKey, keepFraction)
    isAerial   = (Y == 'Aerial');
    aerialUEs  = unique(ueKey(isAerial));
    rep.ueBefore  = numel(aerialUEs);
    rep.rowBefore = sum(isAerial);
    assert(~isempty(aerialUEs), 'phase6_AerialCull:noAerial', ...
        'This side contains no aerial UEs to cull.');

    % At least one aerial UE must survive, or the split becomes single-class.
    nKeep = max(1, round(keepFraction * numel(aerialUEs)));

    % A fixed seed makes the same fraction select the same UEs on every call.
    rngState = rng(42);
    chosen   = aerialUEs(randperm(numel(aerialUEs), nKeep));
    rng(rngState);

    drop  = isAerial & ~ismember(ueKey, chosen);
    X     = X(~drop, :);
    Y     = Y(~drop);
    ueKey = ueKey(~drop);

    rep.ueAfter   = nKeep;
    rep.rowAfter  = sum(Y == 'Aerial');
    rep.rowTotal  = numel(Y);
    rep.share     = mean(Y == 'Aerial');
end

%% ---- print one row of the summary ----
function printSide(name, keepFraction, rep)
    fprintf('%-7s %-9s %-9s %-9s %-9d %.1f%%\n', name, ...
        sprintf('%.0f%%', 100 * keepFraction), ...
        sprintf('%d/%d', rep.ueAfter,  rep.ueBefore), ...
        sprintf('%d/%d', rep.rowAfter, rep.rowBefore), ...
        rep.rowTotal, 100 * rep.share);
end
