function phase5_ReplayRun(scenario, seed, dataDir)
%phase5_ReplayRun Open the saved replay for one batch run.
%
%   phase5_ReplayRun(SCENARIO, SEED)
%   phase5_ReplayRun(SCENARIO, SEED, DATADIR)
%   phase5_ReplayRun()                       browse for a replay file
%
%   Convenience wrapper around replayScenario for the files the batch
%   runner writes. Batch runs execute on parallel workers with no
%   display, so the replay is written to disk rather than shown; this
%   opens it afterwards on the client.
%
%   Example:
%       phase5_ReplayRun("UMa", 7)

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
