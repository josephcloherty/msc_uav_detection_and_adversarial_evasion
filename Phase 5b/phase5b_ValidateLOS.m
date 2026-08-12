function phase5b_ValidateLOS()
%phase5b_ValidateLOS Unit test of the spatially-consistent LOS state.
%
%   Runs in seconds and needs no simulation and no 5G Toolbox objects: it
%   drives buildSpatialField, sampleSpatialField and linkState directly.
%
%   What is checked:
%     1. MARGINAL DISTRIBUTION. The uniform variate must be exactly
%        Uniform(0,1) everywhere, not merely at grid nodes. Plain bilinear
%        interpolation of independent normals swings in variance from 0.25 at
%        a cell centre to 1 at a node, which would bias the threshold test by
%        where in the cell the UE sits. The unit-variance correction in
%        sampleSpatialField is what makes this pass.
%     2. SPATIAL CORRELATION. Points well inside the correlation distance
%        must be strongly correlated and points well beyond it essentially
%        independent, so the state changes on a physical scale rather than
%        flickering per packet.
%     3. PURITY AND DETERMINISM. Sampling the same point twice must agree and
%        rebuilding from the same seed must reproduce the field exactly.
%        Pathloss is evaluated per packet in whatever order the simulator
%        delivers them, so anything stateful would be order dependent and
%        break byte-identical regeneration.
%     4. THE STATE ACTUALLY MOVES. A UE flown across many correlation
%        distances at a mid-range LOS probability must change state. Up to
%        Phase 4 this count was zero by construction.
%     5. PROBABILITY TRACKING. Above the Table B-1 100 % LOS altitude the
%        state must latch to LOS, and at a very low probability it must be
%        NLOS almost everywhere.
%     6. FROZEN FALLBACK. With no field present linkState must return the
%        setup-time draw and report dynamic == false, so archived bundles
%        still replay and are visibly labelled as frozen.
%
%   STATISTICAL TESTS ARE POOLED ACROSS FIELDS. One realisation over a 1 km
%   square holds only a few hundred independent cells, so its spatial mean
%   and variance scatter by about 0.05 and a tight tolerance on one
%   realisation would fail correct code roughly a third of the time. Pooling
%   40 fields shrinks that; every tolerance below came from the observed
%   spread over 60 repeated trials rather than a guess.

    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, 'core', 'functions'));
    fprintf('=== phase5b_ValidateLOS (D5.1) ===\n');

    extent = [-500 500 -500 500];
    dcor   = 50;
    nF     = 40;
    F = buildSpatialField(7, 1000001, nF, extent, dcor);

    %% 1. Marginal distribution at arbitrary (non-node) points
    rs = RandStream('Threefry', 'Seed', 99);
    N = 12000;
    u = zeros(N,1); z = zeros(N,1);
    for i = 1:N
        k = mod(i-1, nF) + 1;
        x = -450 + 900*rand(rs);
        y = -450 + 900*rand(rs);
        [u(i), z(i)] = sampleSpatialField(F, k, x, y);
    end

    check(abs(mean(z)) < 0.08, ...
        sprintf('normal field has zero mean (%.4f)', mean(z)));
    check(abs(var(z) - 1) < 0.10, ...
        sprintf('normal field has unit variance (%.4f)', var(z)));
    check(abs(mean(u) - 0.5) < 0.025, ...
        sprintf('uniform field has mean 0.5 (%.4f)', mean(u)));
    check(abs(var(u) - 1/12) < 0.005, ...
        sprintf('uniform field has variance 1/12 (%.5f)', var(u)));
    check(all(u >= 0 & u <= 1), 'uniform field stays within [0,1]');

    % Uniformity of the whole distribution, not just its moments: every
    % decile should hold about a tenth of the mass.
    dev = max(abs(histcounts(u, 0:0.1:1)/N - 0.1));
    check(dev < 0.02, ...
        sprintf('uniform field decile occupancy flat (max deviation %.4f)', dev));

    %% 2. Spatial correlation
    cNear = pairCorr_(F, nF, rs, 0.2*dcor, 4000);
    cFar  = pairCorr_(F, nF, rs, 3.0*dcor, 4000);
    check(cNear > 0.7, ...
        sprintf('points at 0.2*dcor strongly correlated (r = %.3f)', cNear));
    check(abs(cFar) < 0.10, ...
        sprintf('points at 3*dcor effectively independent (r = %.3f)', cFar));

    %% 3. Purity and determinism
    [ua, za] = sampleSpatialField(F, 1, 123.4, -87.6);
    [ub, zb] = sampleSpatialField(F, 1, 123.4, -87.6);
    check(ua == ub && za == zb, 'repeated sampling of a point is identical');

    F2 = buildSpatialField(7, 1000001, nF, extent, dcor);
    check(ua == sampleSpatialField(F2, 1, 123.4, -87.6), ...
        'rebuilding the field from the same seed reproduces it exactly');

    F3 = buildSpatialField(8, 1000001, nF, extent, dcor);
    check(ua ~= sampleSpatialField(F3, 1, 123.4, -87.6), ...
        'a different seed gives a different field');

    check(ua ~= sampleSpatialField(F, 2, 123.4, -87.6), ...
        'the per-gNB fields are independent of each other');

    %% 4. The state actually moves along a trajectory
    % UMi-AV at 50 m is the right geometry for this test: Table B-1 gives
    % pLOS sweeping roughly 0.83 down to 0.20 across the flight below, so
    % transitions are near-certain for a correct field. UMa-AV at the same
    % height would be a poor test - its pLOS never falls below about 0.91
    % in the 40-100 m band, so even a correct implementation would rarely
    % transition and the test would be flaky rather than informative.
    % (That is also worth knowing in its own right: the frozen state cost
    % least in UMa-AV and most in UMi-AV and for terrestrial UEs.)
    extentBig = [-1000 1000 -1000 1000];
    Fu = buildSpatialField(11, 1000001, 20, extentBig, dcor);
    linkInfoU = mkLinkInfo_(Fu, 20, extentBig, dcor);
    cfgU = struct('scenario', "UMi", 'zBoundary', 22.5, ...
        'enableShadowFading', false);

    gPos = [0 0 25];
    xs = -800:5:800;
    totalTrans = 0; fieldsWithTrans = 0; runLens = [];
    for g = 1:20
        linkInfoU.gnbIdxByID = zeros(1, 40);
        linkInfoU.gnbIdxByID(g) = g;
        states = false(size(xs));
        pl = zeros(size(xs));
        for i = 1:numel(xs)
            st = linkState(linkInfoU, cfgU, g, 30, gPos, [xs(i) 150 50]);
            states(i) = st.isLOS;
            pl(i) = st.pLOS;
        end
        nt = sum(diff(states) ~= 0);
        totalTrans = totalTrans + nt;
        fieldsWithTrans = fieldsWithTrans + (nt >= 1);
        edges = [0, find(diff(states) ~= 0), numel(states)];
        runLens(end+1) = mean(diff(edges)) * 5; %#ok<AGROW>
    end

    check(totalTrans >= 40, ...
        sprintf(['LOS state changes along the flight: %d transitions over ' ...
                 '20 fields (a frozen state gives exactly 0)'], totalTrans));
    check(fieldsWithTrans >= 18, ...
        sprintf('%d of 20 fields show at least one transition', fieldsWithTrans));
    check(mean(runLens) > dcor, ...
        sprintf(['mean run length %.0f m exceeds the %d m correlation ' ...
                 'distance (state changes spatially, it does not flicker)'], ...
                 mean(runLens), dcor));
    check(pl(1) < 0.95 && max(pl) > 0.5, ...
        sprintf('test geometry sweeps a useful pLOS range (%.2f to %.2f)', ...
            min(pl), max(pl)));

    %% 5. The state follows the probability
    linkInfo = mkLinkInfo_(F, nF, extent, dcor);
    cfg = struct('scenario', "UMa", 'zBoundary', 22.5, ...
        'enableShadowFading', true);

    % UMa above 100 m: Table B-1 gives pLOS = 1, so every point is LOS.
    highAllLOS = true;
    for i = 1:numel(xs)
        st = linkState(linkInfo, cfg, 1, 5, gPos, ...
            [max(min(xs(i), 450), -450) 120 150]);
        highAllLOS = highAllLOS && st.isLOS && st.pLOS >= 1 - 1e-12;
    end
    check(highAllLOS, ...
        'above the Table B-1 100 percent LOS altitude the state latches to LOS');

    % A distant ground UE has a very small pLOS, so LOS should be rare.
    losCount = 0; nPts = 0;
    for g = 1:nF
        linkInfo.gnbIdxByID = zeros(1, 40);
        linkInfo.gnbIdxByID(1) = g;
        for y = -450:15:450
            % gNB 1.5 km away, UE at ground height: TR 38.901 UMa gives
            % pLOS of about 0.01 at this separation.
            st = linkState(linkInfo, cfg, 1, 5, [-1400 0 25], [100, y, 1.5]);
            losCount = losCount + st.isLOS; nPts = nPts + 1;
        end
    end
    frac = losCount / nPts;
    check(frac < 0.20, ...
        sprintf('a distant ground UE is mostly NLOS (LOS fraction %.3f)', frac));

    %% Shadow fading follows the live state and is a pure function
    linkInfo.gnbIdxByID = zeros(1, 40); linkInfo.gnbIdxByID(1) = 1;
    st  = linkState(linkInfo, cfg, 1, 5, gPos, [100 100 50]);
    st2 = linkState(linkInfo, cfg, 1, 5, gPos, [100 100 50]);
    check(isfinite(st.sfDB) && abs(st.sfDB) < 60, ...
        sprintf('shadow fading finite and plausible (%.2f dB)', st.sfDB));
    check(st.sfDB == st2.sfDB, 'shadow fading is a pure function of position');

    %% 6. Frozen fallback for archived bundles
    old = struct('los', false(10,10), 'sf', zeros(10,10));
    old.los(1, 5) = true;
    old.sf(1, 5)  = -2.5;
    stOld = linkState(old, cfg, 1, 5, gPos, [100 100 50]);
    check(stOld.isLOS && abs(stOld.sfDB + 2.5) < 1e-12 && ~stOld.dynamic, ...
        'a linkInfo with no field falls back to the frozen setup-time draw');
    check(isfinite(stOld.pLOS), ...
        'the frozen path still reports the live Table B-1 probability');

    fprintf('All LOS state checks passed.\n');
end

%% ----------------------------------------------------------------------
function li = mkLinkInfo_(F, nF, extent, dcor)
%mkLinkInfo_ A linkInfo shaped exactly as createScenarioChannels builds it.
    li = struct();
    li.los = false(40, 40);
    li.sf  = zeros(40, 40);
    li.gnbIDs = 1:nF;
    li.gnbIdxByID = zeros(1, 40);
    li.gnbIdxByID(1) = 1;
    li.dynamicLOS = true;
    li.extent = extent;
    li.dcorLOS = dcor;
    li.losField = F;
    li.sfField = {buildSpatialField(7, 1000002, nF, extent, 37), ...
                  buildSpatialField(7, 1000003, nF, extent, 50)};
end

function r = pairCorr_(F, nF, rs, sep, n)
%pairCorr_ Correlation between field values a fixed distance apart.
    a = zeros(n,1); b = zeros(n,1);
    for i = 1:n
        k = mod(i-1, nF) + 1;
        x = -300 + 600*rand(rs);
        y = -300 + 600*rand(rs);
        th = 2*pi*rand(rs);
        [~, a(i)] = sampleSpatialField(F, k, x, y);
        [~, b(i)] = sampleSpatialField(F, k, ...
            x + sep*cos(th), y + sep*sin(th));
    end
    c = corrcoef(a, b);
    r = c(1,2);
end

function check(cond, what)
    if cond
        fprintf('PASS  %s\n', what);
    else
        error('phase5b_ValidateLOS:fail', 'FAIL: %s', what);
    end
end
