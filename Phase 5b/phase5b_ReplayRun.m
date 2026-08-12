function phase5b_ReplayRun(scenario, seed, dataDir)
%phase5b_ReplayRun Open the saved replay for one batch run.
%
%   phase5b_ReplayRun(SCENARIO, SEED)
%   phase5b_ReplayRun(SCENARIO, SEED, DATADIR)
%   phase5b_ReplayRun()                       browse for a replay file
%
%   Convenience wrapper around replayScenario for the files the batch runner
%   writes. Workers have no display, so the bundle is written to disk and
%   opened afterwards on the client. Only the seeds named in
%   cfg.replay.saveSeeds have one.
%
%   Example:
%       phase5b_ReplayRun("UMa", 7)

    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, 'core', 'functions'));

    if nargin == 0
        replayScenario();   % file browser
        return;
    end
    if nargin < 3 || isempty(dataDir)
        dataDir = fullfile(here, 'data');
    end

    p = fullfile(char(dataDir), sprintf('replay_%s_seed%d.mat', ...
        string(scenario), seed));
    assert(isfile(p), 'phase5b_ReplayRun:notFound', ...
        ['No replay at %s. Check cfg.replay.save was true and that this ' ...
         'seed is in cfg.replay.saveSeeds when the batch ran.'], p);
    replayScenario(p);
end
