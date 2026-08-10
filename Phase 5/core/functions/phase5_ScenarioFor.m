function scenarios = phase5_ScenarioFor(cfg, seeds)
%phase5_ScenarioFor Scenario for each seed. The single source of that answer.
%
%   SCENARIOS = phase5_ScenarioFor(CFG, SEEDS) returns a string array the
%   same size as SEEDS giving the scenario each seed is run under.
%
%   WHY THIS FUNCTION EXISTS
%   The scenario used to be assigned by POSITION in cfg.batch.seedRange:
%   run i took scenarioCycle(mod(i-1,3)+1). That makes the identity of a
%   run depend on the shape of the batch it happened to be enumerated in,
%   which is not a property of the run at all, and it broke three ways in
%   one week:
%     - Prepending seed 34 to 37:59 shifted every later seed by one, so
%       seed 37 became RMa where it would otherwise have been UMa.
%     - The pool trim silently shortened a batch, and a batch whose length
%       is not a multiple of three leaves the scenario counts unbalanced.
%     - Two machines running the same seeds in different-shaped batches
%       disagreed about what seed 46 was, which does not error: each just
%       writes a differently named file, and it surfaces at analysis time.
%
%   Deriving the scenario from the SEED VALUE removes all three. The
%   mapping is then a pure function of the seed, so it is invariant under
%   reordering, trimming, splitting a range across batches, and running on
%   another machine. A contiguous run of seeds whose length is a multiple
%   of numel(scenarioCycle) is balanced wherever it starts.
%
%   MODES (cfg.batch.scenarioFrom)
%     "seed"      scenarioCycle(mod(seed-1, nCycle)+1). The default.
%     "position"  scenarioCycle(mod(i-1, nCycle)+1), the original rule.
%                 Kept only to reproduce a batch enumerated before the
%                 change; it is order dependent and should not be used for
%                 new work.
%
%   OVERRIDES (cfg.batch.scenarioOverride)
%   A struct with fields seed and scenario, pinning named seeds to the
%   scenario they were actually generated under. This is how runs already
%   on disk keep their identity when the rule around them changes: without
%   it, re-enumerating those seeds would resolve them to a different
%   scenario, skipExisting would not recognise the existing CSVs, and the
%   batch would regenerate runs that are already finished under a second
%   name. An override is a record of history, not a preference, so each
%   entry should say in the configuration why it is there.
%
%   See also phase5_RunBatch, phase5_DryRun, phase5_Config.

    cycle = string(cfg.batch.scenarioCycle(:))';
    assert(~isempty(cycle), 'phase5_ScenarioFor:noScenarios', ...
        'cfg.batch.scenarioCycle is empty.');
    nC = numel(cycle);

    sz    = size(seeds);
    seeds = double(seeds(:))';
    n     = numel(seeds);

    mode = "seed";
    if isfield(cfg.batch, 'scenarioFrom') && ...
            strlength(string(cfg.batch.scenarioFrom)) > 0
        mode = lower(string(cfg.batch.scenarioFrom));
    end

    switch mode
        case "seed"
            % mod is non-negative for a positive divisor in MATLAB, so a
            % zero or negative seed still lands inside the cycle.
            scenarios = cycle(mod(seeds - 1, nC) + 1);
        case "position"
            scenarios = cycle(mod((0:n-1), nC) + 1);
        otherwise
            error('phase5_ScenarioFor:badMode', ...
                ['cfg.batch.scenarioFrom must be "seed" or "position", ' ...
                 'not "%s".'], mode);
    end

    %% ---- overrides for seeds generated under an earlier rule -------------
    if isfield(cfg.batch, 'scenarioOverride') && ~isempty(cfg.batch.scenarioOverride)
        ov = cfg.batch.scenarioOverride;
        assert(isstruct(ov) && isfield(ov, 'seed') && isfield(ov, 'scenario'), ...
            'phase5_ScenarioFor:badOverride', ...
            'cfg.batch.scenarioOverride must be a struct with seed and scenario fields.');
        oSeed = double(ov.seed(:))';
        oScen = string(ov.scenario(:))';
        assert(numel(oSeed) == numel(oScen), ...
            'phase5_ScenarioFor:overrideLengthMismatch', ...
            ['cfg.batch.scenarioOverride has %d seed(s) and %d scenario(s); ' ...
             'they must correspond one to one.'], numel(oSeed), numel(oScen));
        assert(numel(unique(oSeed)) == numel(oSeed), ...
            'phase5_ScenarioFor:overrideDuplicateSeed', ...
            'cfg.batch.scenarioOverride names the same seed more than once.');
        % An override naming a scenario that is not in the cycle is almost
        % always a typo, and a typo here writes a run under a name nothing
        % else will ever look for. Caught now rather than after thirty hours.
        bad = ~ismember(oScen, string(fieldnames(cfg.scenarios))');
        assert(~any(bad), 'phase5_ScenarioFor:overrideUnknownScenario', ...
            'cfg.batch.scenarioOverride names undefined scenario(s): %s.', ...
            strjoin(unique(oScen(bad)), ', '));

        [tf, loc] = ismember(seeds, oSeed);
        scenarios(tf) = oScen(loc(tf));
    end

    scenarios = reshape(scenarios, sz);
end
