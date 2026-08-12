function scenarios = phase5b_ScenarioFor(cfg, seeds)
%phase5b_ScenarioFor Scenario for each seed. The single source of that answer.
%
%   SCENARIOS = phase5b_ScenarioFor(CFG, SEEDS) returns a string array the
%   same size as SEEDS giving the scenario each seed is run under.
%
%   The mapping is a pure function of the seed value, so it is invariant
%   under reordering, trimming, splitting a range across batches and running
%   on another machine. Assigning by position in the seed range instead made
%   a run's identity depend on the shape of the batch it was enumerated in,
%   which is not a property of the run, and two machines disagreeing about
%   what a seed is does not error: each writes a differently named file.
%
%   MODES (cfg.batch.scenarioFrom)
%     "seed"      scenarioCycle(mod(seed-1, nCycle)+1). The default.
%     "position"  scenarioCycle(mod(i-1, nCycle)+1), order dependent and kept
%                 only to reproduce a batch enumerated before the change.
%
%   OVERRIDES (cfg.batch.scenarioOverride)
%   A struct with fields seed and scenario, pinning named seeds to the
%   scenario they were actually generated under, so runs already on disk keep
%   their identity when the rule around them changes. Phase 5b regenerates
%   everything, so it carries no overrides.
%
%   See also phase5b_RunBatch, phase5b_DryRun, phase5b_Config.

    cycle = string(cfg.batch.scenarioCycle(:))';
    assert(~isempty(cycle), 'phase5b_ScenarioFor:noScenarios', ...
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
            % mod is non-negative for a positive divisor, so a zero or
            % negative seed still lands inside the cycle.
            scenarios = cycle(mod(seeds - 1, nC) + 1);
        case "position"
            scenarios = cycle(mod((0:n-1), nC) + 1);
        otherwise
            error('phase5b_ScenarioFor:badMode', ...
                ['cfg.batch.scenarioFrom must be "seed" or "position", ' ...
                 'not "%s".'], mode);
    end

    if isfield(cfg.batch, 'scenarioOverride') && ~isempty(cfg.batch.scenarioOverride)
        ov = cfg.batch.scenarioOverride;
        assert(isstruct(ov) && isfield(ov, 'seed') && isfield(ov, 'scenario'), ...
            'phase5b_ScenarioFor:badOverride', ...
            'cfg.batch.scenarioOverride must be a struct with seed and scenario fields.');
        oSeed = double(ov.seed(:))';
        oScen = string(ov.scenario(:))';
        assert(numel(oSeed) == numel(oScen), ...
            'phase5b_ScenarioFor:overrideLengthMismatch', ...
            ['cfg.batch.scenarioOverride has %d seed(s) and %d scenario(s); ' ...
             'they must correspond one to one.'], numel(oSeed), numel(oScen));
        assert(numel(unique(oSeed)) == numel(oSeed), ...
            'phase5b_ScenarioFor:overrideDuplicateSeed', ...
            'cfg.batch.scenarioOverride names the same seed more than once.');
        % A typo here writes a run under a name nothing else will look for.
        bad = ~ismember(oScen, string(fieldnames(cfg.scenarios))');
        assert(~any(bad), 'phase5b_ScenarioFor:overrideUnknownScenario', ...
            'cfg.batch.scenarioOverride names undefined scenario(s): %s.', ...
            strjoin(unique(oScen(bad)), ', '));

        [tf, loc] = ismember(seeds, oSeed);
        scenarios(tf) = oScen(loc(tf));
    end

    scenarios = reshape(scenarios, sz);
end
