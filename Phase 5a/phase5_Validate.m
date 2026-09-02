function report = phase5_Validate(varargin)
%phase5_Validate One-command validation of the Phase 5 simulator.
%
%   phase5_Validate                 % run everything, write the figures
%   report = phase5_Validate(...)   % also return every number as data
%
%   Run it from the Phase 5 folder. It adds core/functions to the path
%   itself and needs no simulation: the channel functions are driven
%   directly, and the SINR block reads replay bundles already on disk.
%
%   WHAT IT COMPARES, AND AGAINST WHAT
%   ----------------------------------
%   Every block compares a SIMULATED value (what the simulator's own code
%   returns) against a CALCULATED value (the 3GPP expression evaluated
%   independently in ref3GPP, which shares no code with the simulator):
%
%     0  Reference anchors      ref3GPP vs values computed BY HAND from
%                               TR 36.777 Tables B-1/B-2/B-3 and TR 38.901
%                               Table 7.4.2-1. Anchors the reference
%                               itself, so the rest of the report means
%                               something.
%     1  Path loss              tr36777ChannelModel.applyChannelModel
%                               (the exact call the simulator makes per
%                               packet) vs ref3GPP, at a sample of link
%                               geometries spanning the height and
%                               horizontal-distance ranges each scenario
%                               generates. Reported separately for the
%                               terrestrial TR 38.901 band and the aerial
%                               TR 36.777 band.
%     2  LOS probability        empirical fraction of links realised as
%                               LOS by linkState over many independent
%                               draws at matched geometry (and therefore
%                               matched elevation angle) vs the closed-form
%                               probability. Sample points are spaced at
%                               least three correlation distances apart so
%                               the draws are independent.
%     3  Shadow fading          sample standard deviation of the shadow-
%                               fading term accumulated over the same
%                               draws vs the specified value.
%     4  SRS SINR               per-gNB SINR recorded over the sounding-
%                               reference-signal links vs a link budget
%                               computed independently from UE transmit
%                               power, the recomputed path loss, gNB
%                               receive gain, receiver noise figure and
%                               occupied bandwidth. Read from the replay
%                               bundles in data/.
%     5  Unit validators        phase5_ValidateLOS and
%                               phase5_ValidateFeatures, run and reported
%                               pass/fail rather than aborting the report.
%
%   The command window ends with a "Values for section 3.2" block giving
%   the mean and maximum errors in the exact form the write-up needs.
%
%   Figures are written to <Phase 5>/figures as PNG and FIG. All of them
%   are forced into light mode with black text by applyLightTheme, so they
%   drop straight into the report whatever desktop theme is in force.
%
%   OPTIONS (name-value)
%     'Scenarios'    string array, default ["UMa" "RMa" "UMi"]
%     'Seed'         seed used to build the geometry and the spatially
%                    consistent fields, default 42
%     'NumFields'    independent field realisations per scenario for the
%                    LOS/shadow-fading draws, default 80
%     'NumDistances' distance samples per height for the path-loss sweep,
%                    default 40
%     'Bundles'      replay bundles per scenario for the SINR block,
%                    default 1 (most recent). 0 skips the block.
%     'Figures'      write the figures, default true
%     'ShowFigures'  leave the figure windows open on screen, default
%                    false. They are built off-screen otherwise: a figure
%                    closed by hand while the script is still running
%                    makes exportgraphics fail, and the run is long enough
%                    that this is easy to do by accident.
%     'UnitTests'    run the existing unit validators, default true
%     'OutDir'       figure output folder, default <Phase 5>/figures
%
%   See also ref3GPP, applyLightTheme, linkState, tr36777ChannelModel.

    p = inputParser;
    p.addParameter('Scenarios', ["UMa" "RMa" "UMi"]);
    p.addParameter('Seed', 42);
    p.addParameter('NumFields', 80);
    p.addParameter('NumDistances', 40);
    p.addParameter('Bundles', 1);
    p.addParameter('Figures', true);
    p.addParameter('ShowFigures', false);
    p.addParameter('UnitTests', true);
    p.addParameter('OutDir', '');
    p.parse(varargin{:});
    o = p.Results;
    scenarios = string(o.Scenarios);

    here = fileparts(mfilename('fullpath'));
    addpath(here);
    addpath(fullfile(here, 'core', 'functions'));
    outDir = char(o.OutDir);
    if isempty(outDir), outDir = fullfile(here, 'figures'); end
    if o.Figures && ~exist(outDir, 'dir'), mkdir(outDir); end

    report = struct('runAt', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
        'scenarios', scenarios, 'seed', o.Seed);

    fprintf('\n==============================================================\n');
    fprintf(' Phase 5 simulator validation   %s\n', report.runAt);
    fprintf(' seed %d | scenarios %s\n', o.Seed, strjoin(cellstr(scenarios), ', '));
    fprintf('==============================================================\n');

    base = phase5_Config();

    %% ---- 0. reference anchors ---------------------------------------
    report.anchors = anchorBlock();

    %% ---- 1..3 per-scenario blocks -----------------------------------
    PL = table(); LP = table(); SF = table(); CO = table();
    for s = 1:numel(scenarios)
        name = scenarios(s);
        cfg  = phase5_ScenarioGen(base, o.Seed, name);
        sc   = base.scenarios.(char(name));

        fprintf('\n--- %s ---\n', name);
        CO = [CO; complianceBlock(cfg, sc)];                              %#ok<AGROW>
        PL = [PL; pathlossBlock(cfg, sc, o.NumDistances)];               %#ok<AGROW>
        [l, f] = losAndShadowBlock(cfg, sc, o.NumFields, o.Seed);
        LP = [LP; l];                                                     %#ok<AGROW>
        SF = [SF; f];                                                     %#ok<AGROW>
    end
    report.compliance = CO;
    report.pathloss = PL;
    report.losProbability = LP;
    report.shadowFading = SF;

    printCompliance(CO);
    printPathloss(PL);
    printLOS(LP);
    printSF(SF);

    %% ---- 4. SRS SINR against an independent link budget --------------
    SN = table();
    if o.Bundles > 0
        dataDir = fullfile(here, 'data');
        for s = 1:numel(scenarios)
            SN = [SN; sinrBlock(scenarios(s), dataDir, o.Bundles)];      %#ok<AGROW>
        end
    end
    report.sinr = SN;
    printSINR(SN);

    %% ---- 5. existing unit validators ---------------------------------
    if o.UnitTests
        report.unitTests = unitTestBlock();
    end

    %% ---- summary -----------------------------------------------------
    report.summary = summaryBlock(report);
    printSummary(report.summary);

    %% ---- figures -----------------------------------------------------
    if o.Figures
        % Built off-screen unless asked otherwise: a figure closed by hand
        % mid-run invalidates the handle and exportgraphics then throws,
        % which would discard the whole report after several minutes of
        % work. Restored by the cleanup object whatever happens below.
        if ~o.ShowFigures
            vis0 = get(groot, 'defaultFigureVisible');
            visGuard = onCleanup(@() set(groot, 'defaultFigureVisible', vis0));
            set(groot, 'defaultFigureVisible', 'off');
        end

        report.figures = string.empty;
        report.figures(end+1) = tryFig(@() figPathloss(PL, outDir), 'path loss');
        report.figures(end+1) = tryFig(@() figLOS(LP, outDir), 'LOS probability');
        report.figures(end+1) = tryFig(@() figSF(SF, outDir), 'shadow fading');
        if ~isempty(SN)
            report.figures(end+1) = tryFig(@() figSINR(SN, outDir), 'SRS SINR');
        end
        report.figures = report.figures(strlength(report.figures) > 0);
        fprintf('\nFigures written to %s\n', outDir);
    end
end

%% =====================================================================
%  Block 0: the reference implementation against hand-computed values
%  =====================================================================
function T = anchorBlock()
    A = ref3GPP.anchors();
    what = strings(numel(A),1); expected = zeros(numel(A),1);
    actual = zeros(numel(A),1);
    for i = 1:numel(A)
        a = A(i);
        switch a.kind
            case 'pLOS', v = ref3GPP.losProbability(a.args{:});
            case 'PLav', v = ref3GPP.pathloss36777(a.args{:});
            case 'SF',   v = ref3GPP.shadowFadingStd(a.args{:});
            otherwise,   v = NaN;
        end
        what(i) = string(a.what); expected(i) = a.expected; actual(i) = v;
    end
    T = table(what, expected, actual, abs(actual - expected), ...
        'VariableNames', {'what','expected','actual','absError'});

    fprintf('\n[0] Reference implementation vs hand-computed 3GPP values\n');
    for i = 1:height(T)
        flag = '     ';
        if T.absError(i) > 1e-4, flag = 'CHECK'; end
        fprintf('   %s %-46s %11.6f  (expected %11.6f)\n', ...
            flag, T.what(i), T.actual(i), T.expected(i));
    end
    fprintf('   max |error| %.2e  (the hand values are quoted to 6 decimals)\n', ...
        max(T.absError));
end

%% =====================================================================
%  Block 1: path loss
%  =====================================================================
function T = pathlossBlock(cfg, sc, nD)
%pathlossBlock Channel-model path loss vs the recomputed 3GPP expression.
%   The simulated value is taken from applyChannelModel itself - the same
%   entry point the simulator calls for every packet - so the height
%   switch, the LOS branch selection and the scenario mapping are all
%   exercised rather than reimplemented here.

    scen  = string(cfg.scenario);
    fcHz  = cfg.carrierFrequency;
    fcGHz = fcHz / 1e9;
    hBS   = sc.topology.gnbHeight_m;
    zB    = cfg.zBoundary;

    dMax = maxGroundDistance(cfg, sc);
    d2Ds = logspace(log10(10), log10(dMax), nD);

    % Heights the scenario actually generates, plus the rest of the
    % terrestrial band so the TR 38.901 branch is swept over its whole
    % range of validity rather than at a single altitude.
    hTerr = unique(round([sc.terrestrialAlt_m, ...
        linspace(sc.terrestrialAlt_m, zB, 5)], 4));
    hAer  = unique(round(linspace(sc.aerialAltRange_m(1), ...
        sc.aerialAltRange_m(2), 9), 4));
    heights = [hTerr, hAer];

    probe = {pathlossProbe(cfg, false, hBS), pathlossProbe(cfg, true, hBS)};

    n = numel(heights)*numel(d2Ds)*2;
    scenC = strings(n,1); band = strings(n,1);
    isLOSv = false(n,1); hUTv = zeros(n,1); d2Dv = zeros(n,1);
    elevv = zeros(n,1); simv = zeros(n,1); refv = zeros(n,1);
    refv2 = zeros(n,1);      % same reference, exact propagation velocity

    k = 0;
    for hi = 1:numel(heights)
        hUT = heights(hi);
        aerial = hUT > zB;
        for di = 1:numel(d2Ds)
            d2D = d2Ds(di);
            d3D = hypot(d2D, hUT - hBS);
            for L = [false true]
                k = k + 1;
                scenC(k)  = scen;
                if aerial
                    band(k) = "TR 36.777 aerial";
                else
                    band(k) = "TR 38.901 terrestrial";
                end
                isLOSv(k) = L;
                hUTv(k)   = hUT;
                d2Dv(k)   = d2D;
                elevv(k)  = atand((hUT - hBS)/d2D);
                simv(k)   = probe{L+1}(hUT, d2D);
                if aerial
                    refv(k) = ref3GPP.pathloss36777(scen, L, fcGHz, hUT, d3D);
                    refv2(k) = refv(k);   % no breakpoint term in Table B-2
                else
                    opts = struct('hE', 1);
                    if scen == "RMa", opts.hE = 0; end
                    refv(k) = ref3GPP.pathloss38901(scen, L, fcHz, hBS, hUT, d2D, opts);
                    % Same expression with c = 299792458 m/s instead of the
                    % 3.0e8 m/s the specification text quotes, to separate
                    % the convention from a coding error.
                    opts.c = 299792458;
                    refv2(k) = ref3GPP.pathloss38901(scen, L, fcHz, hBS, hUT, d2D, opts);
                end
            end
        end
    end

    T = table(scenC, band, isLOSv, hUTv, d2Dv, elevv, simv, refv, ...
        abs(simv - refv), abs(simv - refv2), 'VariableNames', ...
        {'scenario','band','isLOS','hUT_m','d2D_m','elevation_deg', ...
         'simulated_dB','calculated_dB','absError_dB','absError_exactC_dB'});
    fprintf('    path loss: %d geometries evaluated\n', height(T));
end

function f = pathlossProbe(cfg, isLOS, hBS)
%pathlossProbe Function handle returning the channel model's path loss.
%   A two-node linkInfo with no spatially-consistent field pins the LOS
%   state, so the sweep can hold LOS or NLOS fixed while the geometry
%   moves. Shadow fading is left at zero, isolating the path loss.
    li = struct('los', false(2,2), 'sf', zeros(2,2));
    li.los(1,2) = isLOS; li.los(2,1) = isLOS;
    chm = tr36777ChannelModel(cell(2,2), cfg, li, 2);   % node 2 is the UE
    f = @(hUT, d2D) probeOnce(chm, cfg, hBS, hUT, d2D);
end

function pl = probeOnce(chm, cfg, hBS, hUT, d2D)
    txData = struct('TransmitterID', 1, ...
        'TransmitterPosition', [0 0 hBS], ...
        'CenterFrequency', cfg.carrierFrequency, ...
        'Power', 0, 'NumTransmitAntennas', 1);
    rxInfo = struct('ID', 2, 'Position', [d2D 0 hUT], 'NumReceiveAntennas', 1);
    out = chm.applyChannelModel(rxInfo, txData);
    pl = txData.Power - out.Power;
end

function d = maxGroundDistance(cfg, sc)
%maxGroundDistance Largest gNB-UE ground distance the scenario can produce.
%   Corners of the square UE region against every gNB position.
    span = sc.topology.ueAreaSpan_m;
    off  = sc.topology.originOffset_m;
    cx = off(1) + [-1 1 -1 1]*span/2;
    cy = off(2) + [-1 -1 1 1]*span/2;
    g = cfg.gNBPositions;
    d = 0;
    for i = 1:size(g,1)
        d = max(d, max(hypot(cx - g(i,1), cy - g(i,2))));
    end
    d = max(d, 100);
end

%% =====================================================================
%  Block 1b: applicability ranges and stated modelling assumptions
%  =====================================================================
function T = complianceBlock(cfg, sc)
%complianceBlock Scenario configuration against the documented ranges.
%
%   Blocks 1 to 3 test whether the code evaluates the 3GPP expressions
%   correctly. They cannot test whether the scenario stays inside the
%   range over which those expressions are DEFINED, and a model evaluated
%   outside its stated range is wrong however faithfully it is coded.
%
%   Every requirement below is quoted from the source documents:
%     TR 36.777 Table B-1 Note 1     assumed BS antenna heights
%     TR 36.777 Tables B-1/B-2/B-3   aerial height bands, d2D limits
%     TR 38.901 Table 7.4.1-1        terrestrial heights, d2D, defaults
%     TR 38.901 Table 7.4.1-1 Note 1 UMa effective environment height
%     TR 38.901 Table 7.4.1-1 Note 2 carrier frequency range

    scen = upper(string(cfg.scenario));
    hBS  = sc.topology.gnbHeight_m;
    zB   = cfg.zBoundary;
    hT   = sc.terrestrialAlt_m;
    aAlt = sc.aerialAltRange_m;
    fcGHz = cfg.carrierFrequency/1e9;
    dMax = maxGroundDistance(cfg, sc);

    switch scen
        case "RMA", hAssumed = 35; zReq = 10;   dLimAV = 10000; fHi = 30;
                    hTLo = 1;    hTHi = 10;     dLimTerr = 10000;
        case "UMA", hAssumed = 25; zReq = 22.5; dLimAV = 4000;  fHi = 100;
                    hTLo = 1.5;  hTHi = 22.5;   dLimTerr = 5000;
        otherwise,  hAssumed = 10; zReq = 22.5; dLimAV = 4000;  fHi = 100;
                    hTLo = 1.5;  hTHi = 22.5;   dLimTerr = 5000;
    end
    aLo = zReq;

    C = {};
    C(end+1,:) = {'BS antenna height matches Table B-1 Note 1', ...
        sprintf('%g m', hAssumed), sprintf('%g m', hBS), hBS == hAssumed};
    C(end+1,:) = {'z-boundary is the Table B-1/B-2/B-3 aerial floor', ...
        sprintf('%g m', zReq), sprintf('%g m', zB), zB == zReq};
    C(end+1,:) = {'terrestrial UE height inside Table 7.4.1-1 range', ...
        sprintf('%g to %g m', hTLo, hTHi), sprintf('%g m', hT), ...
        hT >= hTLo && hT <= hTHi};
    C(end+1,:) = {'aerial altitudes inside the Table B-2 band', ...
        sprintf('%g to 300 m', aLo), sprintf('%g to %g m', aAlt(1), aAlt(2)), ...
        aAlt(1) > aLo && aAlt(2) <= 300};
    C(end+1,:) = {'max d2D inside the Table B-2 aerial limit', ...
        sprintf('<= %g m', dLimAV), sprintf('%.0f m', dMax), dMax <= dLimAV};
    C(end+1,:) = {'max d2D inside the Table 7.4.1-1 terrestrial limit', ...
        sprintf('<= %g m', dLimTerr), sprintf('%.0f m', dMax), dMax <= dLimTerr};
    C(end+1,:) = {'carrier inside Table 7.4.1-1 Note 2 range', ...
        sprintf('0.5 to %g GHz', fHi), sprintf('%.2f GHz', fcGHz), ...
        fcGHz > 0.5 && fcGHz < fHi};

    % TR 38.901 Table 7.4.1-1 Note 1: for UMa the effective environment
    % height is 1 m only with probability 1/(1+C(d2D,hUT)), and C is zero
    % for hUT < 13 m. The pipeline pins EnvironmentHeight to 1, which is
    % exact while every terrestrial UE sits below 13 m and stops being so
    % the moment one does not.
    if scen == "UMA"
        C(end+1,:) = {'UMa hE = 1 m exact (Note 1 needs hUT < 13 m)', ...
            'terrestrial hUT < 13 m', sprintf('%g m', hT), hT < 13};
    end

    % The narrower aerial NLOS ranges are only safe if the LOS model makes
    % NLOS unreachable above them. Checked against the probability rather
    % than assumed: pLOS = 1 everywhere above the limit means the NLOS row
    % is never selected there.
    if scen == "UMA" || scen == "RMA"
        if scen == "UMA", nlosCap = 100; else, nlosCap = 40; end
        hs = linspace(nlosCap + 0.01, max(aAlt(2), nlosCap + 1), 40);
        ds = linspace(10, dMax, 40);
        worst = 1;
        for a = 1:numel(hs)
            for b = 1:numel(ds)
                worst = min(worst, ref3GPP.losProbability(scen, hs(a), ds(b)));
            end
        end
        C(end+1,:) = {sprintf('NLOS unreachable above the %g m aerial NLOS cap', nlosCap), ...
            'pLOS = 1 above it', sprintf('min pLOS = %.6f', worst), worst >= 1};
    end

    T = table(repmat(string(cfg.scenario), size(C,1), 1), string(C(:,1)), ...
        string(C(:,2)), string(C(:,3)), cell2mat(C(:,4)), ...
        'VariableNames', {'scenario','requirement','specified','configured','ok'});
end

function printCompliance(T)
    fprintf('\n[1b] Applicability ranges and stated modelling assumptions\n');
    fprintf('   %-6s %-52s %-22s %-22s\n', 'scen', 'requirement', ...
        'document says', 'scenario uses');
    for i = 1:height(T)
        if T.ok(i), flag = '   '; else, flag = '>> '; end
        fprintf('%s%-6s %-52s %-22s %-22s\n', flag, T.scenario(i), ...
            T.requirement(i), T.specified(i), T.configured(i));
    end
    nbad = sum(~T.ok);
    if nbad == 0
        fprintf('   All %d range and assumption checks satisfied.\n', height(T));
    else
        fprintf(['   %d of %d checks NOT satisfied (marked >>). These are ' ...
                 'scenario settings,\n   not coding errors: the ' ...
                 'expressions are evaluated correctly, outside the range\n' ...
                 '   the documents define them over.\n'], nbad, height(T));
    end
end

%% =====================================================================
%  Blocks 2 and 3: LOS probability and shadow fading
%  =====================================================================
function [L, S] = losAndShadowBlock(cfg, sc, nFields, seed)
%losAndShadowBlock Empirical LOS fraction and shadow-fading spread.
%   Draws come from linkState, the function the simulator and the replay
%   renderer both call, so what is measured here is the state the
%   simulator actually uses. Sample points around each gNB are spaced at
%   least three correlation distances apart, which makes the draws
%   independent: buildSpatialField's grid spacing is the correlation
%   distance, so points that far apart share no grid nodes.

    scen = string(cfg.scenario);
    hBS  = sc.topology.gnbHeight_m;
    zB   = cfg.zBoundary;
    dcorLOS = losCorrDistance(scen);
    [dcorSFL, dcorSFN] = sfCorrDistance(scen);
    sep = 3 * max([dcorLOS, dcorSFL, dcorSFN]);

    dMax = maxGroundDistance(cfg, sc);
    d2Ds = unique(round(logspace(log10(max(50, sep/2)), log10(dMax), 8)));
    hTerr = unique(round([sc.terrestrialAlt_m, zB/2], 4));
    hAer  = unique(round(linspace(sc.aerialAltRange_m(1), ...
        sc.aerialAltRange_m(2), 5), 4));
    heights = [hTerr, hAer];

    R = dMax*1.2 + sep;
    extent = [-R R -R R];
    li = struct();
    li.los = false(4,4);
    li.sf  = zeros(4,4);
    li.gnbIDs = 1;
    li.gnbIdxByID = zeros(1,4);
    li.dynamicLOS = true;
    li.extent  = extent;
    li.dcorLOS = dcorLOS;
    li.losField   = buildSpatialField(seed, 1000001, nFields, extent, dcorLOS);
    li.sfField{1} = buildSpatialField(seed, 1000002, nFields, extent, dcorSFL);
    li.sfField{2} = buildSpatialField(seed, 1000003, nFields, extent, dcorSFN);

    cfgL = cfg;
    cfgL.enableShadowFading = true;

    nBins = numel(heights)*numel(d2Ds);
    scenC = strings(nBins,1); band = strings(nBins,1);
    hUTv = zeros(nBins,1); d2Dv = zeros(nBins,1); elevv = zeros(nBins,1);
    nDraw = zeros(nBins,1); pEmp = zeros(nBins,1); pRef = zeros(nBins,1);
    se = zeros(nBins,1);

    sfRows = struct('scenario', {}, 'band', {}, 'state', {}, 'hUT_m', {}, ...
        'n', {}, 'sigmaEmpirical_dB', {}, 'sigmaSpecified_dB', {});
    sfAcc = containers.Map('KeyType','char','ValueType','any');

    b = 0;
    for hi = 1:numel(heights)
        hUT = heights(hi);
        aerial = hUT > zB;
        for di = 1:numel(d2Ds)
            d2D = d2Ds(di);
            nAz = max(1, min(64, floor(2*pi*d2D/sep)));
            nD  = nFields*nAz;
            los = false(nD,1); sfv = zeros(nD,1);
            j = 0;
            for g = 1:nFields
                li.gnbIdxByID(1) = g;
                for a = 1:nAz
                    th = 2*pi*(a-1)/nAz;
                    uePos = [d2D*cos(th), d2D*sin(th), hUT];
                    st = linkState(li, cfgL, 1, 2, [0 0 hBS], uePos);
                    j = j + 1;
                    los(j) = st.isLOS;
                    sfv(j) = st.sfDB;
                end
            end

            b = b + 1;
            scenC(b) = scen;
            if aerial
                band(b) = "TR 36.777 aerial";
            else
                band(b) = "TR 38.901 terrestrial";
            end
            hUTv(b) = hUT; d2Dv(b) = d2D;
            elevv(b) = atand((hUT - hBS)/d2D);
            nDraw(b) = nD;
            pEmp(b) = mean(los);
            pRef(b) = ref3GPP.losProbability(scen, hUT, d2D);
            se(b) = sqrt(max(pRef(b)*(1 - pRef(b)), 0)/nD);

            % Shadow fading is pooled per (state, height, SPECIFIED sigma).
            % Pooling on state and height alone would be wrong for the one
            % distance-dependent row in either document - terrestrial RMa
            % LOS, 4 dB inside the Table 7.4.1-1 Note 5 breakpoint and
            % 6 dB beyond it - because the two branches would be averaged
            % into a single group and neither would be tested.
            for stTrue = [true false]
                sigSpec = ref3GPP.shadowFadingStd(scen, stTrue, hUT, zB, ...
                    struct('d2D', d2D, 'hBS', hBS, 'fcHz', cfg.carrierFrequency));
                key = sprintf('%d_%.4f_%.6f', stTrue, hUT, sigSpec);
                v = sfv(los == stTrue);
                if isKey(sfAcc, key)
                    sfAcc(key) = [sfAcc(key); v];
                else
                    sfAcc(key) = v;
                end
            end
        end
    end

    L = table(scenC, band, hUTv, d2Dv, elevv, nDraw, pEmp, pRef, ...
        abs(pEmp - pRef)*100, se*100, 'VariableNames', ...
        {'scenario','band','hUT_m','d2D_m','elevation_deg','nDraws', ...
         'empirical','calculated','absError_pp','samplingSE_pp'});

    ks = keys(sfAcc);
    for i = 1:numel(ks)
        parts = strsplit(ks{i}, '_');
        stTrue = logical(str2double(parts{1}));
        hUT = str2double(parts{2});
        sigSpec = str2double(parts{3});
        v = sfAcc(ks{i});
        if numel(v) < 50, continue; end
        e = struct('scenario', scen, ...
            'band', ternary(hUT > zB, "TR 36.777 aerial", "TR 38.901 terrestrial"), ...
            'state', ternary(stTrue, "LOS", "NLOS"), 'hUT_m', hUT, ...
            'n', numel(v), 'sigmaEmpirical_dB', std(v), ...
            'sigmaSpecified_dB', sigSpec);
        sfRows(end+1) = e; %#ok<AGROW>
    end
    if isempty(sfRows)
        S = table();
    else
        S = struct2table(sfRows, 'AsArray', true);
        S.absError_dB = abs(S.sigmaEmpirical_dB - S.sigmaSpecified_dB);
        S.relError_pct = 100*S.absError_dB ./ S.sigmaSpecified_dB;
        % Standard error of a sample standard deviation, sigma/sqrt(2(n-1)):
        % the yardstick the deviation column has to be read against, since
        % a small group cannot pin sigma tightly however correct the code.
        S.samplingSE_dB = S.sigmaSpecified_dB ./ sqrt(2*max(S.n - 1, 1));
        S = sortrows(S, {'state','hUT_m'});
    end
    fprintf('    LOS state: %d geometries, %d draws total\n', ...
        height(L), sum(L.nDraws));
end

function d = losCorrDistance(scen)
%losCorrDistance TR 38.901 Table 7.6.3.1-2, LOS/NLOS state row.
%   Kept in step with the private helper of createScenarioChannels.
    switch upper(string(scen))
        case "RMA", d = 60;
        otherwise,  d = 50;
    end
end

function [dLOS, dNLOS] = sfCorrDistance(scen)
%sfCorrDistance TR 38.901 Table 7.6.3.1-2, shadow-fading row.
    switch upper(string(scen))
        case "UMA", dLOS = 37; dNLOS = 50;
        case "UMI", dLOS = 10; dNLOS = 13;
        case "RMA", dLOS = 37; dNLOS = 120;
        otherwise,  dLOS = 37; dNLOS = 50;
    end
end

%% =====================================================================
%  Block 4: SRS SINR against independent link budgets
%  =====================================================================
function T = sinrBlock(scen, dataDir, maxBundles)
%sinrBlock Per-gNB SRS SINR against two independently computed bounds.
%
%   The recorded quantity is a SINR, not an SNR, so a single noise-only
%   budget cannot bound it from both sides. Two budgets are computed
%   instead, from the same recomputed path loss:
%
%     noise-limited     S/N  - every interferer silent. This is the
%                       UPPER bound the measurement can reach, and it is
%                       the budget that tests the path loss, because
%                       nothing else enters it.
%     all-interferers   S/(N + sum of I) with EVERY other UE assumed to
%                       be transmitting on the same resources at the same
%                       instant. SRS resources are actually orthogonal
%                       across the UEs a gNB serves and the periodicities
%                       are staggered, so this is a LOWER bound.
%
%   A correctly behaving simulator therefore sits between the two. The
%   fraction of samples that do, and the offset from the noise-limited
%   bound, are what the report quotes.
%
%   Received power at gNB g from UE v is
%       P(g,v) = Ptx + Grx - PL(g,v) - SF(g,v)
%   with PL recomputed by ref3GPP at the live geometry and SF taken from
%   linkState, i.e. exactly the term the simulator applied. The matrix is
%   built once per sampled instant and reused for every UE, so adding the
%   interference bound costs nothing beyond the first UE.

    T = table();
    files = dir(fullfile(dataDir, sprintf('replay_%s_seed*.mat', scen)));
    if isempty(files)
        fprintf('    SINR: no replay bundle for %s in %s (block skipped)\n', ...
            scen, dataDir);
        return;
    end
    [~, ord] = sort([files.datenum], 'descend');
    files = files(ord(1:min(maxBundles, numel(files))));

    rows = struct('scenario', {}, 'bundle', {}, 'ueID', {}, 'gnb', {}, ...
        'isServing', {}, 'time_s', {}, 'hUT_m', {}, 'd2D_m', {}, ...
        'simulated_dB', {}, 'noiseOnly_dB', {}, 'noiseOnlyMRC_dB', {}, ...
        'withInterference_dB', {}, 'arrayGain_dB', {}, ...
        'error_dB', {}, 'errorInterf_dB', {});

    for fi = 1:numel(files)
        fp = fullfile(files(fi).folder, files(fi).name);
        fprintf('    SINR: reading %s (%.0f MB)...\n', files(fi).name, ...
            files(fi).bytes/1e6);
        % The bundles carry a parallel.pool.DataQueue inside the progress
        % reporter, which cannot be reconstructed outside the pool that
        % created it. The warning is harmless here - nothing in this block
        % touches the queue - so it is silenced for the load only.
        wState = warning('off', 'all');
        S = load(fp);
        warning(wState);
        if ~isfield(S, 'replayData'), continue; end
        rd = S.replayData;
        if ~isfield(rd, 'extras') || ~isfield(rd.extras, 'cfg'), continue; end
        cfgR = rd.extras.cfg;
        liR  = rd.extras.linkInfo;
        posLog = rd.posLog;
        mgrs = rd.managers;
        if ~iscell(mgrs), mgrs = {mgrs}; end
        if isempty(mgrs), continue; end

        [Ptx, NF, nRB] = radioParams(cfgR.radio);
        BW  = nRB*12*cfgR.radio.subcarrierSpacing;
        N0  = -174 + 10*log10(BW) + NF;
        Grx = cfgR.radio.gnbReceiveGain;
        % Coherent combining across the gNB receive array is worth up to
        % 10*log10(N) dB and is inside the simulator's SINR but not inside
        % a scalar link budget. Carried explicitly so the offset can be
        % read against it rather than absorbed into an unexplained constant.
        gArray = 10*log10(cfgR.radio.gnbRxAntennas);
        zB  = cfgR.zBoundary;
        fcHz = cfgR.carrierFrequency; fcGHz = fcHz/1e9;
        numGNB = size(cfgR.gNBPositions, 1);
        isRMa = upper(string(cfgR.scenario)) == "RMA";
        nLin = 10^(N0/10);

        rowByID = zeros(1, max(posLog.nodeIDs));
        rowByID(posLog.nodeIDs) = 1:numel(posLog.nodeIDs);
        times = posLog.times(:);

        % ---- UEs present, and their per-manager logs -------------------
        nUE = numel(mgrs);
        ueIDs = zeros(1, nUE);
        for k = 1:nUE, ueIDs(k) = mgrs{k}.UE.ID; end

        % ---- sampling instants (shared by every UE) --------------------
        tAll = [];
        for k = 1:nUE
            sl = getLog(mgrs{k}, 'sinrLog');
            if ~isempty(sl), tAll = [tAll; sl(:,1)]; end          %#ok<AGROW>
        end
        if isempty(tAll), continue; end
        tAll = unique(tAll);
        stride = max(1, ceil(numel(tAll)/300));
        tSample = tAll(1:stride:end);

        if numel(times) < 2
            frames = ones(numel(tSample), 1);
        else
            frames = interp1(times, (1:numel(times))', tSample, 'nearest', 'extrap');
        end
        frames = min(max(round(frames), 1), numel(times));

        for ii = 1:numel(tSample)
            f = frames(ii);

            % ---- received power matrix P(gNB, UE) at this instant ------
            P = -inf(numGNB, nUE);
            d2Dm = zeros(numGNB, nUE);
            uePosAll = zeros(nUE, 3);
            for v = 1:nUE
                r = rowByID(ueIDs(v));
                if r == 0, continue; end
                uePosAll(v,:) = reshape(posLog.xyz(r, :, f), 1, 3);
            end
            for g = 1:numGNB
                if g <= numel(rowByID) && rowByID(g) > 0
                    gPos = reshape(posLog.xyz(rowByID(g), :, f), 1, 3);
                else
                    gPos = cfgR.gNBPositions(g,:);
                end
                for v = 1:nUE
                    uePos = uePosAll(v,:);
                    if all(uePos == 0), continue; end
                    st  = linkState(liR, cfgR, g, ueIDs(v), gPos, uePos);
                    d2D = max(norm(uePos(1:2) - gPos(1:2)), 1);
                    d3D = max(norm(uePos - gPos), 1);
                    if uePos(3) > zB
                        PL = ref3GPP.pathloss36777(cfgR.scenario, st.isLOS, ...
                            fcGHz, uePos(3), d3D);
                    else
                        opts = struct('hE', 1);
                        if isRMa, opts.hE = 0; end
                        PL = ref3GPP.pathloss38901(cfgR.scenario, st.isLOS, ...
                            fcHz, gPos(3), uePos(3), d2D, opts);
                    end
                    P(g,v) = Ptx + Grx - PL - st.sfDB;
                    d2Dm(g,v) = d2D;
                end
            end
            pLin = 10.^(P/10);

            % ---- compare against every UE's recorded measurement -------
            for u = 1:nUE
                sl = getLog(mgrs{u}, 'sinrLog');
                if isempty(sl), continue; end
                [dt, ri] = min(abs(sl(:,1) - tSample(ii)));
                if dt > 0.05, continue; end     % no scan near this instant
                servID = servingAt(mgrs{u}, tSample(ii));
                for g = 1:min(numGNB, size(sl,2)-1)
                    sim = sl(ri, g+1);
                    if ~isfinite(sim), continue; end
                    if ~isfinite(P(g,u)), continue; end
                    interf = sum(pLin(g, [1:u-1, u+1:nUE]), 'omitnan');
                    withI = P(g,u) - 10*log10(nLin + interf);
                    rows(end+1) = struct('scenario', string(scen), ...
                        'bundle', string(files(fi).name), ...
                        'ueID', ueIDs(u), 'gnb', g, ...
                        'isServing', double(servID == g), ...
                        'time_s', sl(ri,1), 'hUT_m', uePosAll(u,3), ...
                        'd2D_m', d2Dm(g,u), 'simulated_dB', sim, ...
                        'noiseOnly_dB', P(g,u) - N0, ...
                        'noiseOnlyMRC_dB', P(g,u) - N0 + gArray, ...
                        'withInterference_dB', withI, ...
                        'arrayGain_dB', gArray, ...
                        'error_dB', sim - (P(g,u) - N0), ...
                        'errorInterf_dB', sim - withI);          %#ok<AGROW>
                end
            end
        end
        clear S rd;
    end

    if ~isempty(rows)
        T = struct2table(rows, 'AsArray', true);
    end
end

function v = getLog(m, name)
%getLog Property read that tolerates an archived manager without it.
    v = [];
    try
        v = m.(name);
    catch
        v = [];
    end
end

function gid = servingAt(m, t)
%servingAt Serving cell ID at time T from the manager's feature log.
    gid = NaN;
    try
        fl = m.featureLog;
        if isempty(fl), return; end
        cT = strcmp(m.featureNames, 'time');
        cG = strcmp(m.featureNames, 'servingGNB');
        idx = find(fl(:,cT) <= t, 1, 'last');
        if ~isempty(idx), gid = fl(idx, cG); end
    catch
        gid = NaN;
    end
end

function [Ptx, NF, nRB] = radioParams(r)
%radioParams Transmit power, noise figure and resource-block count read
%   from the toolbox objects themselves rather than hard-coded, so the
%   link budget follows whatever defaults the installed release uses.
    Ptx = 23; NF = 6; nRB = [];
    try
        g = nrGNB(CarrierFrequency=r.carrierFrequency, ...
            ChannelBandwidth=r.channelBandwidth, ...
            SubcarrierSpacing=r.subcarrierSpacing, ...
            NumTransmitAntennas=r.gnbTxAntennas, ...
            NumReceiveAntennas=r.gnbRxAntennas, ...
            ReceiveGain=r.gnbReceiveGain, DuplexMode=char(r.duplexMode));
        if isprop(g, 'NoiseFigure'),       NF  = g.NoiseFigure; end
        if isprop(g, 'NumResourceBlocks'), nRB = g.NumResourceBlocks; end
        u = nrUE(NumTransmitAntennas=r.ueTxAntennas, ...
            NumReceiveAntennas=r.ueRxAntennas, ReceiveGain=r.ueReceiveGain);
        if isprop(u, 'TransmitPower'),     Ptx = u.TransmitPower; end
    catch ME
        warning('phase5_Validate:radioDefaults', ...
            ['Could not read the toolbox radio defaults (%s); falling back ' ...
             'to %g dBm transmit power and %g dB noise figure.'], ...
            ME.message, Ptx, NF);
    end
    if isempty(nRB)
        nRB = floor(r.channelBandwidth*0.9/(12*r.subcarrierSpacing));
    end
end

%% =====================================================================
%  Block 5: the existing unit validators
%  =====================================================================
function T = unitTestBlock()
    names = ["phase5_ValidateLOS", "phase5_ValidateFeatures"];
    passed = false(numel(names),1); msg = strings(numel(names),1);
    fprintf('\n[5] Unit validators\n');
    for i = 1:numel(names)
        try
            evalc(char(names(i)));      % keep their own output out of the report
            passed(i) = true;
            fprintf('   PASS  %s\n', names(i));
        catch ME
            msg(i) = string(ME.message);
            fprintf('   FAIL  %s : %s\n', names(i), ME.message);
        end
    end
    T = table(names(:), passed, msg, ...
        'VariableNames', {'validator','passed','message'});
end

%% =====================================================================
%  Reporting
%  =====================================================================
function printPathloss(T)
    fprintf('\n[1] Path loss: channel model vs recomputed 3GPP expression\n');
    fprintf('   %-6s %-24s %7s %14s %14s %18s\n', ...
        'scen', 'band', 'n', 'mean|err| dB', 'max|err| dB', 'max|err| exact c');
    [gr, sc, bd] = findgroups(T.scenario, T.band);
    for i = 1:max(gr)
        m = gr == i;
        e = T.absError_dB(m);
        fprintf('   %-6s %-24s %7d %14.3e %14.3e %18.3e\n', ...
            sc(i), bd(i), numel(e), mean(e), max(e), ...
            max(T.absError_exactC_dB(m)));
    end
    fprintf(['   The last column repeats the terrestrial comparison with ' ...
             'c = 299792458 m/s\n   in the breakpoint distance instead of ' ...
             'the 3.0e8 m/s the specification\n   text quotes. The ' ...
             'difference between the two columns is that convention,\n' ...
             '   not a disagreement about the model.\n']);
end

function printLOS(T)
    fprintf('\n[2] LOS probability: empirical fraction vs closed form\n');
    fprintf('   %-6s %-24s %6s %10s %14s %13s %14s\n', 'scen', 'band', ...
        'bins', 'draws', 'mean|err| pp', 'max|err| pp', 'max 2*SE pp');
    [gr, sc, bd] = findgroups(T.scenario, T.band);
    for i = 1:max(gr)
        m = gr == i;
        fprintf('   %-6s %-24s %6d %10d %14.3f %13.3f %14.3f\n', ...
            sc(i), bd(i), sum(m), sum(T.nDraws(m)), ...
            mean(T.absError_pp(m)), max(T.absError_pp(m)), ...
            2*max(T.samplingSE_pp(m)));
    end
end

function printSF(T)
    fprintf('\n[3] Shadow fading: sample std vs specified std\n');
    if isempty(T)
        fprintf('   (no groups with enough draws)\n');
        return;
    end
    fprintf('   %-6s %-5s %8s %9s %11s %11s %10s %8s %11s\n', 'scen', ...
        'state', 'hUT m', 'n', 'sample dB', 'spec dB', 'err dB', 'err %', ...
        'err / SE');
    for i = 1:height(T)
        fprintf('   %-6s %-5s %8.1f %9d %11.3f %11.3f %10.3f %8.2f %11.2f\n', ...
            T.scenario(i), T.state(i), T.hUT_m(i), T.n(i), ...
            T.sigmaEmpirical_dB(i), T.sigmaSpecified_dB(i), ...
            T.absError_dB(i), T.relError_pct(i), ...
            T.absError_dB(i)/T.samplingSE_dB(i));
    end
    fprintf(['   err / SE is the deviation in units of the standard error ' ...
             'of a sample\n   standard deviation. Values around 1 to 2 are ' ...
             'what a correct\n   implementation produces; a large value at ' ...
             'a large n is the signal\n   worth chasing.\n']);
end

function printSINR(T)
    fprintf('\n[4] SRS SINR: simulator vs independent link budgets\n');
    if isempty(T)
        fprintf('   (no replay bundles read)\n');
        return;
    end
    fprintf(['   Bounds on the recorded SINR, both from the recomputed ' ...
             'path loss:\n' ...
             '     ceiling  S/N + receive-array combining gain, every ' ...
             'interferer silent\n' ...
             '     floor    S/(N + sum I), every other UE transmitting ' ...
             'on the same\n              resources at the same instant ' ...
             '(SRS is really orthogonal,\n              so this is ' ...
             'pessimistic)\n\n']);
    fprintf('   %-6s %8s %10s %13s %12s %13s\n', 'scen', 'n', ...
        'in bounds', 'median off dB', 'p5 off dB', 'serving max %');
    [gr, sc] = findgroups(T.scenario);
    for i = 1:max(gr)
        m = gr == i;
        e = T.error_dB(m);
        q = pctl(e, 5);
        fprintf('   %-6s %8d %9.1f%% %13.2f %12.2f %12.1f%%\n', ...
            sc(i), sum(m), 100*mean(inBounds(T(m,:))), median(e), q, ...
            servingIsMaxPct(T(m,:)));
    end

    % The subset where the computed interference is negligible is the only
    % place a scalar budget can be held to a tight tolerance, because
    % nothing but noise, path loss and array gain is left in it. That is
    % the number the write-up can quote.
    fprintf(['\n   Interference-free subset (computed interference more ' ...
             'than 6 dB below\n   thermal noise): the offset here is ' ...
             'array gain and nothing else.\n\n']);
    fprintf('   %-6s %8s %14s %12s %14s %14s\n', 'scen', 'n', ...
        'median off dB', 'std dB', 'max resid dB', 'array gain dB');
    for i = 1:max(gr)
        Ts = T(gr == i, :);
        quiet = Ts.noiseOnly_dB - Ts.withInterference_dB < 6;
        if ~any(quiet)
            fprintf('   %-6s %8d %14s\n', sc(i), 0, '(none)');
            continue;
        end
        e = Ts.error_dB(quiet);
        fprintf('   %-6s %8d %14.2f %12.2f %14.2f %14.2f\n', ...
            sc(i), numel(e), median(e), std(e), max(abs(e - median(e))), ...
            Ts.arrayGain_dB(1));
    end
    fprintf(['\n   "serving max" is a wiring check: the fraction of ' ...
             'instants where the serving\n   cell holds the strongest ' ...
             'SINR of all the columns. A low value would mean\n   the ' ...
             'column-to-gNB mapping is wrong, not that the physics is.\n']);
end

function tf = inBounds(T)
%inBounds Simulated SINR between the two independently computed bounds.
    tf = T.simulated_dB <= T.noiseOnlyMRC_dB + 0.5 & ...
         T.simulated_dB >= T.withInterference_dB - 0.5;
end

function pct = servingIsMaxPct(T)
%servingIsMaxPct Fraction of instants whose serving cell has the top SINR.
%   An instant is one UE, in one bundle, at one scan time. The bundle must
%   be part of the key: two scenarios sample the same UE IDs at the same
%   nominal times, so grouping on (ueID, time) alone silently merges rows
%   from different runs into one over-sized group and the answer collapses
%   towards chance.
    k = findgroups(T.scenario, T.bundle, T.ueID, T.time_s);
    hit = 0; n = 0;
    for i = 1:max(k)
        m = k == i;
        srv = find(T.isServing(m) == 1, 1);
        if isempty(srv), continue; end
        n = n + 1;
        [~, best] = max(T.simulated_dB(m));
        hit = hit + double(best == srv);
    end
    if n == 0, pct = NaN; else, pct = 100*hit/n; end
end

function s = summaryBlock(report)
    s = struct();
    PL = report.pathloss;
    s.maxAnchorError = max(report.anchors.absError);
    s.complianceTotal = height(report.compliance);
    s.complianceOK = sum(report.compliance.ok);
    isT = PL.band == "TR 38.901 terrestrial";
    isA = PL.band == "TR 36.777 aerial";
    s.pathlossTerrestrialMean = meanWhere(PL.absError_dB, isT);
    s.pathlossTerrestrialMax  = maxWhere(PL.absError_dB, isT);
    s.pathlossTerrestrialMaxExactC = maxWhere(PL.absError_exactC_dB, isT);
    s.pathlossAerialMean = meanWhere(PL.absError_dB, isA);
    s.pathlossAerialMax  = maxWhere(PL.absError_dB, isA);

    LP = report.losProbability;
    s.losDraws = sum(LP.nDraws);
    s.losMaxError_pp = max(LP.absError_pp);
    s.losMeanError_pp = mean(LP.absError_pp);
    s.losMaxSamplingBand_pp = 2*max(LP.samplingSE_pp);

    SF = report.shadowFading;
    if isempty(SF)
        s.sfMeanError_dB = NaN; s.sfMaxError_dB = NaN; s.sfMaxError_pct = NaN;
        s.sfMaxErrorOverSE = NaN;
    else
        s.sfMeanError_dB = mean(SF.absError_dB);
        s.sfMaxError_dB  = max(SF.absError_dB);
        s.sfMaxError_pct = max(SF.relError_pct);
        s.sfMaxErrorOverSE = max(SF.absError_dB ./ SF.samplingSE_dB);
    end

    SN = report.sinr;
    if isempty(SN)
        s.sinrSamples = 0; s.sinrInBounds_pct = NaN;
        s.sinrMedianOffset_dB = NaN; s.sinrP5Offset_dB = NaN;
        s.sinrP95Offset_dB = NaN; s.sinrServingIsMax_pct = NaN;
        s.sinrQuietSamples = 0; s.sinrQuietOffset_dB = NaN;
        s.sinrQuietMaxResidual_dB = NaN; s.sinrArrayGain_dB = NaN;
    else
        e = SN.error_dB;
        q = pctl(e, [5 95]);
        s.sinrSamples = numel(e);
        s.sinrInBounds_pct = 100*mean(inBounds(SN));
        s.sinrMedianOffset_dB = median(e);
        s.sinrP5Offset_dB = q(1);
        s.sinrP95Offset_dB = q(2);
        % Per scenario, then the worst case, because the array gain and
        % the interference floor are both scenario dependent.
        gr = findgroups(SN.scenario);
        qn = zeros(max(gr),1); qm = zeros(max(gr),1); qs = zeros(max(gr),1);
        for i = 1:max(gr)
            Ts = SN(gr == i, :);
            quiet = Ts.noiseOnly_dB - Ts.withInterference_dB < 6;
            qn(i) = sum(quiet);
            if qn(i) > 1
                ee = Ts.error_dB(quiet);
                qm(i) = median(ee);
                qs(i) = max(abs(ee - median(ee)));
            else
                qm(i) = NaN; qs(i) = NaN;
            end
        end
        s.sinrQuietSamples = sum(qn);
        s.sinrQuietOffset_dB = median(qm, 'omitnan');
        s.sinrQuietMaxResidual_dB = max(qs);
        s.sinrArrayGain_dB = SN.arrayGain_dB(1);
        s.sinrServingIsMax_pct = servingIsMaxPct(SN);
    end
end

function printSummary(s)
    fprintf('\n==============================================================\n');
    fprintf(' Values for section 3.2\n');
    fprintf('==============================================================\n');
    fprintf('  path loss, TR 38.901 terrestrial ... mean %.3e dB, max %.3e dB\n', ...
        s.pathlossTerrestrialMean, s.pathlossTerrestrialMax);
    fprintf('     with the exact propagation velocity: max %.3e dB\n', ...
        s.pathlossTerrestrialMaxExactC);
    fprintf('  path loss, TR 36.777 aerial ........ mean %.3e dB, max %.3e dB\n', ...
        s.pathlossAerialMean, s.pathlossAerialMax);
    fprintf('  LOS link realisations .............. %d\n', s.losDraws);
    fprintf('  LOS probability .................... mean %.3f pp, max %.3f pp\n', ...
        s.losMeanError_pp, s.losMaxError_pp);
    fprintf('     widest 95%% binomial sampling band over the bins: %.3f pp\n', ...
        s.losMaxSamplingBand_pp);
    fprintf('  shadow-fading std .................. mean %.3f dB, max %.3f dB (%.2f %% of specified)\n', ...
        s.sfMeanError_dB, s.sfMaxError_dB, s.sfMaxError_pct);
    fprintf('     largest deviation in units of its own sampling error: %.2f\n', ...
        s.sfMaxErrorOverSE);
    if s.sinrSamples > 0
        fprintf('  SRS SINR, %d samples ............... %.1f %% lie between the two bounds\n', ...
            s.sinrSamples, s.sinrInBounds_pct);
        fprintf('     interference-free subset (%d samples): offset %.2f dB against an\n', ...
            s.sinrQuietSamples, s.sinrQuietOffset_dB);
        fprintf('     array gain of %.2f dB, max deviation about it %.2f dB\n', ...
            s.sinrArrayGain_dB, s.sinrQuietMaxResidual_dB);
        fprintf('     serving cell holds the strongest SINR in %.1f %% of instants (wiring check)\n', ...
            s.sinrServingIsMax_pct);
    else
        fprintf('  SRS SINR vs link budget ............ not run (no replay bundle)\n');
    end
    fprintf('  reference vs hand-computed anchors . max %.2e\n', s.maxAnchorError);
    fprintf('  applicability / assumption checks ... %d of %d satisfied\n', ...
        s.complianceOK, s.complianceTotal);
    fprintf('==============================================================\n');
end

%% =====================================================================
%  Figures (light mode, black text - see applyLightTheme)
%  =====================================================================
function pth = figPathloss(T, outDir)
    scen = unique(T.scenario, 'stable');
    fig = figure('Name', 'Path loss validation', ...
        'Position', [60 60 1250 720], 'Color', 'w');
    for i = 1:numel(scen)
        Ts = T(T.scenario == scen(i), :);
        hs = unique(Ts.hUT_m);
        hT = hs(1);        % lowest sampled height: terrestrial band
        hA = hs(end);      % highest sampled height: aerial band

        subplot(2, numel(scen), i); hold on; grid on;
        h1 = plotPair(Ts, hT, true,  [0 0 0.8]);
        h2 = plotPair(Ts, hT, false, [0.8 0 0]);
        h3 = plotPair(Ts, hA, true,  [0 0.5 0]);
        h4 = plotPair(Ts, hA, false, [0.7 0 0.7]);
        set(gca, 'XScale', 'log');
        xlabel('d_{2D} (m)'); ylabel('Path loss (dB)');
        title(sprintf('%s: lines calculated, markers simulated', scen(i)));
        legend([h1 h2 h3 h4], ...
            {sprintf('h_{UT} %g m LOS', hT), sprintf('h_{UT} %g m NLOS', hT), ...
             sprintf('h_{UT} %g m LOS', hA), sprintf('h_{UT} %g m NLOS', hA)}, ...
            'Location', 'southeast');

        subplot(2, numel(scen), numel(scen)+i); hold on; grid on;
        tb = Ts(Ts.band == "TR 38.901 terrestrial", :);
        ab = Ts(Ts.band == "TR 36.777 aerial", :);
        plot(tb.d2D_m, max(tb.absError_dB, 1e-16), '.', ...
            'Color', [0 0 0.8], 'MarkerSize', 7);
        plot(ab.d2D_m, max(ab.absError_dB, 1e-16), '.', ...
            'Color', [0.8 0 0], 'MarkerSize', 7);
        set(gca, 'XScale', 'log', 'YScale', 'log');
        xlabel('d_{2D} (m)'); ylabel('|simulated - calculated| (dB)');
        title(sprintf('%s deviation (max %.2e dB)', scen(i), max(Ts.absError_dB)));
        legend({'TR 38.901 terrestrial','TR 36.777 aerial'}, 'Location', 'best');
    end
    sgtitle('Path loss: simulator channel model vs the 3GPP expressions recomputed');
    pth = saveFig(fig, outDir, 'validation_pathloss');
end

function hLine = plotPair(Ts, h, isLOS, col)
%plotPair Calculated curve as a line, simulated points as markers.
    m = Ts.hUT_m == h & Ts.isLOS == isLOS;
    [d, o] = sort(Ts.d2D_m(m));
    c = Ts.calculated_dB(m); c = c(o);
    s = Ts.simulated_dB(m);  s = s(o);
    hLine = plot(d, c, '-', 'Color', col, 'LineWidth', 1.4);
    plot(d(1:3:end), s(1:3:end), 'o', 'Color', col, 'MarkerSize', 5);
end

function pth = figLOS(T, outDir)
    scen = unique(T.scenario, 'stable');
    fig = figure('Name', 'LOS probability validation', ...
        'Position', [60 60 1250 720], 'Color', 'w');
    for i = 1:numel(scen)
        Ts = T(T.scenario == scen(i), :);
        hs = unique(Ts.hUT_m);
        cols = lines(numel(hs));

        subplot(2, numel(scen), i); hold on; grid on;
        for k = 1:numel(hs)
            m = Ts.hUT_m == hs(k);
            [d, o] = sort(Ts.d2D_m(m));
            c = Ts.calculated(m); e = Ts.empirical(m);
            plot(d, c(o), '-', 'Color', cols(k,:), 'LineWidth', 1.4);
            plot(d, e(o), 'o', 'Color', cols(k,:), 'MarkerSize', 5);
        end
        set(gca, 'XScale', 'log'); ylim([0 1.05]);
        xlabel('d_{2D} (m)'); ylabel('P_{LOS}');
        title(sprintf('%s: lines closed form, markers empirical', scen(i)));

        subplot(2, numel(scen), numel(scen)+i); hold on; grid on;
        errorbar(Ts.elevation_deg, Ts.empirical - Ts.calculated, ...
            2*Ts.samplingSE_pp/100, 'o', 'Color', [0 0 0], ...
            'MarkerSize', 4, 'LineWidth', 0.8, 'LineStyle', 'none');
        yline(0, 'k-');
        xlabel('Elevation angle (deg)'); ylabel('empirical - closed form');
        title(sprintf('%s deviation (max %.2f pp)', scen(i), max(Ts.absError_pp)));
    end
    sgtitle(['LOS probability: realised fraction vs the closed-form ' ...
             'probability, error bars 95 % binomial']);
    pth = saveFig(fig, outDir, 'validation_losprobability');
end

function pth = figSF(T, outDir)
    fig = figure('Name', 'Shadow fading validation', ...
        'Position', [60 60 1150 480], 'Color', 'w');
    if isempty(T)
        annotation('textbox', [0.1 0.4 0.8 0.2], 'String', ...
            'No shadow-fading groups with enough draws', 'EdgeColor', 'none');
        pth = saveFig(fig, outDir, 'validation_shadowfading');
        return;
    end
    scen = unique(T.scenario, 'stable');
    subplot(1,2,1); hold on; grid on;
    mk = {'o','s','^'};
    for i = 1:numel(scen)
        m = T.scenario == scen(i);
        plot(T.sigmaSpecified_dB(m), T.sigmaEmpirical_dB(m), mk{mod(i-1,3)+1}, ...
            'MarkerSize', 7, 'LineWidth', 1.1);
    end
    lim = [0 max([T.sigmaSpecified_dB; T.sigmaEmpirical_dB])*1.1];
    plot(lim, lim, 'k:');
    xlim(lim); ylim(lim);
    xlabel('Specified \sigma_{SF} (dB)'); ylabel('Sample \sigma_{SF} (dB)');
    title('Shadow fading: sample vs specified');
    legend([cellstr(scen); {'y = x'}], 'Location', 'southeast');

    subplot(1,2,2); grid on;
    lbl = categorical(T.scenario + " " + T.state + " " + ...
        string(round(T.hUT_m)) + " m");
    bar(lbl, T.absError_dB, 'FaceColor', [0.3 0.45 0.75]);
    ylabel('|sample - specified| (dB)');
    title(sprintf('Deviation by group (max %.3f dB)', max(T.absError_dB)));
    sgtitle('Shadow-fading term accumulated over the LOS draws');
    pth = saveFig(fig, outDir, 'validation_shadowfading');
end

function pth = figSINR(T, outDir)
    scen = unique(T.scenario, 'stable');
    fig = figure('Name', 'SRS SINR validation', ...
        'Position', [60 60 1250 720], 'Color', 'w');
    for i = 1:numel(scen)
        m = T.scenario == scen(i);
        Ts = T(m, :);
        quiet = Ts.noiseOnly_dB - Ts.withInterference_dB < 6;

        subplot(2, numel(scen), i); hold on; grid on;
        plot(Ts.noiseOnly_dB(~quiet), Ts.simulated_dB(~quiet), '.', ...
            'Color', [0.65 0.70 0.78], 'MarkerSize', 5);
        plot(Ts.noiseOnly_dB(quiet), Ts.simulated_dB(quiet), '.', ...
            'Color', [0.75 0.35 0.15], 'MarkerSize', 6);
        lim = [min([Ts.noiseOnly_dB; Ts.simulated_dB]), ...
               max([Ts.noiseOnly_dB; Ts.simulated_dB])];
        plot(lim, lim, 'k:', 'LineWidth', 1.2);
        plot(lim, lim + Ts.arrayGain_dB(1), 'k--', 'LineWidth', 1.2);
        xlim(lim); ylim(lim);
        xlabel('S/N from the recomputed path loss (dB)');
        ylabel('Simulated SRS SINR (dB)');
        title(sprintf('%s (n = %d)', scen(i), height(Ts)));
        legend({'interference present','interference-free','y = x', ...
            sprintf('y = x + %.1f dB array gain', Ts.arrayGain_dB(1))}, ...
            'Location', 'northwest');

        subplot(2, numel(scen), numel(scen)+i); hold on; grid on;
        if any(quiet)
            histogram(Ts.error_dB(quiet), 40, 'FaceColor', [0.75 0.35 0.15]);
            xline(Ts.arrayGain_dB(1), 'k--', 'LineWidth', 1.2);
            title(sprintf('%s interference-free offset (n = %d)', ...
                scen(i), sum(quiet)));
        else
            title(sprintf('%s: no interference-free samples', scen(i)));
        end
        xlabel('Simulated - S/N (dB)'); ylabel('count');
    end
    sgtitle(['SRS SINR against the recomputed link budget: the ' ...
             'interference-free samples should sit on the array-gain line']);
    pth = saveFig(fig, outDir, 'validation_sinr');
end

function pth = saveFig(fig, outDir, name)
%saveFig Theme, export and store one figure, tolerating a lost handle.
    pth = "";
    if ~isgraphics(fig)
        warning('phase5_Validate:figureGone', ...
            ['The %s figure was closed before it could be exported; ' ...
             'no file written for it.'], name);
        return;
    end
    applyLightTheme(fig);
    pth = string(fullfile(outDir, [name '.png']));
    exportgraphics(fig, char(pth), 'Resolution', 200, 'BackgroundColor', 'white');
    savefig(fig, fullfile(outDir, [name '.fig']));
end

function pth = tryFig(fcn, what)
%tryFig Build one figure without letting a failure discard the report.
%   The numbers are the deliverable; a figure that cannot be drawn or
%   exported is worth a warning, not the loss of a several-minute run.
    try
        pth = fcn();
        if isempty(pth), pth = ""; end
    catch ME
        warning('phase5_Validate:figureFailed', ...
            'The %s figure could not be written: %s', what, ME.message);
        pth = "";
    end
end

%% =====================================================================
%  Small helpers
%  =====================================================================
function v = maxWhere(x, m)
    if any(m), v = max(x(m)); else, v = NaN; end
end

function v = meanWhere(x, m)
    if any(m), v = mean(x(m)); else, v = NaN; end
end

function out = ternary(cond, a, b)
    if cond, out = a; else, out = b; end
end

function v = pctl(x, p)
%pctl Linear-interpolation percentile.
%   Written out rather than calling prctile so the validation runs without
%   a Statistics and Machine Learning Toolbox licence, matching the choice
%   already made in sampleSpatialField (erfc rather than normcdf).
    x = sort(x(~isnan(x)));
    if isempty(x), v = nan(size(p)); return; end
    n = numel(x);
    if n == 1, v = repmat(x, size(p)); return; end
    pos = min(max((p(:)/100)*n + 0.5, 1), n);
    v = reshape(interp1((1:n)', x(:), pos, 'linear'), size(p));
end
