function scenarios = phase5_ScenarioFor(cfg, seeds)
% returns the scenario each seed runs under, derived from the seed value so it
% does not depend on the shape or order of the batch.

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
            % mod keeps a non-positive seed inside the cycle
            scenarios = cycle(mod(seeds - 1, nC) + 1);
        case "position"
            scenarios = cycle(mod((0:n-1), nC) + 1);
        otherwise
            error('phase5_ScenarioFor:badMode', ...
                ['cfg.batch.scenarioFrom must be "seed" or "position", ' ...
                 'not "%s".'], mode);
    end

    %% overrides for seeds generated under an earlier rule
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
        % an override naming an unknown scenario is almost always a typo
        bad = ~ismember(oScen, string(fieldnames(cfg.scenarios))');
        assert(~any(bad), 'phase5_ScenarioFor:overrideUnknownScenario', ...
            'cfg.batch.scenarioOverride names undefined scenario(s): %s.', ...
            strjoin(unique(oScen(bad)), ', '));

        [tf, loc] = ismember(seeds, oSeed);
        scenarios(tf) = oScen(loc(tf));
    end

    scenarios = reshape(scenarios, sz);
end
