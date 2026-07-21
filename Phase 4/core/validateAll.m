function validateAll(runSlow)
%validateAll Run the Phase 4 validation suite, mapped to the plan's phases.
%
%   validateAll()      runs the fast checks (seconds to ~a minute):
%
%     tr36777SelfTest            Phase 3   channel maths against the 3GPP
%                                          equations (Tables B-1/B-2/B-3,
%                                          38.901 baselines, CDL scaling,
%                                          UMi reverse-UMa builder)
%     validateFeatureExtraction  Phase 4   D4.2 windowed extraction, schema
%                                          lock/prefix, CQI/MCS/traffic
%                                          features, byte-identical CSV
%     validateTrafficSources     Phase 4   D4.1 per-class traffic profiles,
%                                          TR 36.777 C2 shape, asymmetry,
%                                          burstiness, determinism
%     phase4SchedulerCheck       Phase 4   D4.1 custom scheduler route on
%                                          R2024b (short probe simulation)
%
%   validateAll(true)  additionally runs the slow checks:
%
%     validateAerialOverlay      Phase 3   D3.2/D3.3 before/after overlay
%       ('UMa') and ('RMa')                figures (saved to figures/)
%     validateUMiOverlay         Phase 3   D3.4 UMi figures (optional fork)
%     validatePhase4EndToEnd     Phases    full pipeline smoke run: object
%       (with reproducibility)   1 to 4    model and mobility (Phase 1/2),
%                                          measurement and channels
%                                          (Phase 3), scheduler logging,
%                                          traffic and CSV (Phase 4), plus
%                                          the byte-identical re-run
%
%   Each script also runs standalone. A failure stops the suite with the
%   failing check named; passing output ends with the summary line.

    if nargin < 1, runSlow = false; end
    here = fileparts(mfilename('fullpath'));
    addpath(here, fullfile(here, 'functions'), fullfile(here, '..', 'umi'));

    steps = { ...
        'tr36777SelfTest (Phase 3 channel maths)', @() tr36777SelfTest(); ...
        'validateFeatureExtraction (D4.2)',        @() validateFeatureExtraction(); ...
        'validateTrafficSources (D4.1)',           @() validateTrafficSources(); ...
        'phase4SchedulerCheck (D4.1, R2024b)',     @() phase4SchedulerCheck()};
    if runSlow
        steps = [steps; { ...
            'validateAerialOverlay UMa (D3.2)',    @() validateAerialOverlay('UMa'); ...
            'validateAerialOverlay RMa (D3.3)',    @() validateAerialOverlay('RMa'); ...
            'validateUMiOverlay (D3.4)',           @() validateUMiOverlay(); ...
            'validatePhase4EndToEnd + repro',      @() validatePhase4EndToEnd(true)}];
    end

    t0 = tic;
    for i = 1:size(steps, 1)
        fprintf('\n########## [%d/%d] %s ##########\n', i, size(steps,1), steps{i,1});
        steps{i,2}();
    end
    fprintf('\n=== validateAll: %d/%d suites passed in %.1f min ===\n', ...
        size(steps,1), size(steps,1), toc(t0)/60);
    if ~runSlow
        fprintf('(figures and the end-to-end smoke run: validateAll(true))\n');
    end
end
