function phase5_ReplayRun(scenario, seed, dataDir)
% opens the saved replay for one batch run, or browses for a file when called
% with no arguments.

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
    assert(isfile(p), 'phase5_ReplayRun:notFound', ...
        ['No replay at %s. Check cfg.replay.save was true when the ' ...
         'batch ran, and that the scenario and seed are ones the batch ' ...
         'covered.'], p);
    replayScenario(p);
end
