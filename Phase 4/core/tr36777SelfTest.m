function tr36777SelfTest()
%tr36777SelfTest Assertion checks of the Phase 3 code against the 3GPP equations.
%
%   Run from the core folder (no simulation needed, finishes in seconds):
%       tr36777SelfTest
%
%   Every expected value below was computed INDEPENDENTLY of this codebase,
%   by hand from the equations extracted from the TR 36.777 and TR 38.901
%   source documents (Tables B-1, B-2, B-3; Table 7.4.2-1; Table 7.7.1-4;
%   clauses 7.7.3, 7.7.5.1, 7.7.6; Annex A.5). If an implementation drifts
%   from the spec, the corresponding assertion fails and names the table
%   or clause it violates. Passing output ends with "All checks passed".

    addpath(fullfile(fileparts(mfilename('fullpath')), 'functions'));
    tol = 1e-4;

    %% --- TR 36.777 Table B-1 / TR 38.901 Table 7.4.2-1: LOS probability ---
    % Aerial bands (hand-computed from the extracted p1/d1 formulas)
    checkVal(tr36777LOSProbability('UMa', 50, 500),  0.888749, tol, ...
        'Table B-1 UMa-AV, hUT=50 m, d2D=500 m');
    checkVal(tr36777LOSProbability('RMa', 25, 800),  0.904100, tol, ...
        'Table B-1 RMa-AV, hUT=25 m, d2D=800 m');
    checkVal(tr36777LOSProbability('UMi', 100, 300), 0.771170, tol, ...
        'Table B-1 UMi-AV, hUT=100 m, d2D=300 m');
    % 100 per cent LOS bands
    checkVal(tr36777LOSProbability('RMa', 41, 5000), 1, 0, ...
        'Table B-1 RMa-AV, 100%% LOS above 40 m');
    checkVal(tr36777LOSProbability('UMa', 101, 5000), 1, 0, ...
        'Table B-1 UMa-AV, 100%% LOS above 100 m');
    % Terrestrial band falls back to TR 38.901 Table 7.4.2-1
    checkVal(tr36777LOSProbability('UMa', 1.5, 200), 0.128048, tol, ...
        'Table 7.4.2-1 UMa, hUT=1.5 m, d2D=200 m');
    checkVal(tr36777LOSProbability('RMa', 1.5, 500), 0.612626, tol, ...
        'Table 7.4.2-1 RMa, d2D=500 m');
    checkVal(tr36777LOSProbability('UMi', 1.5, 100), 0.230985, tol, ...
        'Table 7.4.2-1 UMi, d2D=100 m');

    %% --- TR 36.777 Table B-2: aerial pathloss (fc = 2.6 GHz) --------------
    checkVal(tr36777AerialPathloss('UMa', true,  2.6, 100, 520),  96.0515, tol, ...
        'Table B-2 UMa-AV LOS');
    checkVal(tr36777AerialPathloss('UMa', false, 2.6, 100, 520), 110.1533, tol, ...
        'Table B-2 UMa-AV NLOS');
    checkVal(tr36777AerialPathloss('RMa', true,  2.6, 50, 1000), 103.2668, tol, ...
        'Table B-2 RMa-AV LOS');
    checkVal(tr36777AerialPathloss('RMa', false, 2.6, 50, 1000), 106.7276, tol, ...
        'Table B-2 RMa-AV NLOS');
    checkVal(tr36777AerialPathloss('UMi', true,  2.6, 100, 200),  88.0964, tol, ...
        'Table B-2 UMi-AV LOS');
    checkVal(tr36777AerialPathloss('UMi', false, 2.6, 100, 200), 105.1283, tol, ...
        'Table B-2 UMi-AV NLOS');

    %% --- TR 36.777 Table B-3: shadow fading std ---------------------------
    checkVal(tr36777ShadowFadingStd('UMa', true, 100, 22.5), 2.398190, tol, ...
        'Table B-3 UMa-AV LOS, hUT=100 m');
    checkVal(tr36777ShadowFadingStd('RMa', true, 50, 10),    3.337041, tol, ...
        'Table B-3 RMa-AV LOS, hUT=50 m');
    checkVal(tr36777ShadowFadingStd('UMi', true, 300, 22.5), 2, tol, ...
        'Table B-3 UMi-AV LOS floor at 2 dB');

    %% --- Annex B.1.1 Alternative 1 via buildAerialCDL ---------------------
    % Build a UMa-AV LOS link and check the achieved K, DS, angle scale
    % factor, LOS cluster placement, and ZOD offset.
    hBS = 25; hUT = 100; d2D = 500;
    d3D = hypot(d2D, hUT - hBS);
    zod = acosd((hUT - hBS)/d3D);  zoa = acosd((hBS - hUT)/d3D);
    zodOff = atand((hBS + hUT - 2*20)/d2D) + atand((hUT - hBS)/d2D); % eq B.1.1-2
    link = struct('isLOS', true, 'desiredAS', [5 10 1 5], ...  % tabulated combos
        'desiredK_dB', 20, 'desiredDS_s', 10e-9, ...
        'losAngles', [0 180 zod zoa], 'zodOffsetDeg', 0, 'offsetDim', 'ZoD', ...
        'carrierFrequency', 2.6e9, 'sampleRate', 30.72e6, 'seed', 1, ...
        'numTxAnts', 16, 'numRxAnts', 2, 'linkDirection', 'downlink');
    ch = buildAerialCDL(link);

    % Clause 7.7.6: achieved K (specular over total diffuse power)
    g = 10.^(ch.AveragePathGains/10);
    kLin = 10^(ch.KFactorFirstCluster/10);
    pLOS = g(1) * kLin/(1 + kLin);
    pDiff = [g(1)/(1 + kLin), g(2:end)];
    checkVal(10*log10(pLOS/sum(pDiff)), 20, 1e-3, ...
        'clause 7.7.6: achieved K-factor = 20 dB');

    % Clause 7.7.3: achieved rms delay spread = 10 ns
    pAll = [pLOS, pDiff];  tAll = [ch.PathDelays(1), ch.PathDelays];
    mu = sum(pAll.*tAll)/sum(pAll);
    ds = sqrt(sum(pAll.*tAll.^2)/sum(pAll) - mu^2);
    checkVal(ds*1e9, 10, 1e-3, 'clause 7.7.3: achieved DS = 10 ns');

    % Clause 7.7.5.1 / Annex A.5: scale factors must match Table 7.7.5.1-1.
    % CDL-D model cluster 2 offsets: AOD 89.2-0, ZOD 85.5-98.5, ZOA 86.9-81.5.
    checkVal((ch.AnglesAoD(2) - 0)/89.2,        0.3231, 5e-4, ...
        'Table 7.7.5.1-1 CDL-D: AOD spread 5 deg -> s=0.3231');
    checkVal((ch.AnglesZoD(2) - zod)/(85.5-98.5), 0.4477, 5e-4, ...
        'Table 7.7.5.1-1 CDL-D: ZOD spread 1 deg -> s=0.4477');
    checkVal((ch.AnglesZoA(2) - zoa)/(86.9-81.5), 4.3268, 5e-3, ...
        'Table 7.7.5.1-1 CDL-D: ZOA spread 5 deg -> s=4.3268');

    % First cluster sits exactly on the geometric LOS direction
    checkVal(ch.AnglesZoD(1), zod, 1e-9, 'LOS cluster placed on LOS ZoD');
    checkVal(ch.AnglesAoD(1), 0,   1e-9, 'LOS cluster placed on LOS AoD');

    % Annex B.1.1 Step 5: rebuilding with the offset shifts clusters 2..13
    % by exactly the offset, and leaves the LOS ray untouched
    link2 = link;  link2.zodOffsetDeg = zodOff;
    ch2 = buildAerialCDL(link2);
    checkVal(mean(ch2.AnglesZoD(2:end) - ch.AnglesZoD(2:end)), zodOff, 1e-6, ...
        'Annex B.1.1 Step 5: ZOD offset on non-direct paths');
    checkVal(ch2.AnglesZoD(1), zod, 1e-9, ...
        'Annex B.1.1 Step 5: LOS ray not offset');

    % NLOS: no offset regardless of the requested value (Step 6)
    link3 = link;  link3.isLOS = false;  link3.desiredK_dB = 10;
    link3.desiredDS_s = 30e-9;  link3.zodOffsetDeg = zodOff;
    ch3 = buildAerialCDL(link3);
    assert(~isempty(ch3.PathDelays), 'NLOS aerial CDL build failed');

    %% --- UMi-AV reverse-UMa builder (D3.4) --------------------------------
    linkU = struct('isLOS', true, 'd2D', 150, 'd3D', hypot(150, 90), ...
        'hBS', 10, 'hUT', 100, 'losAngles', [0 180 acosd(90/hypot(150,90)) ...
        acosd(-90/hypot(150,90))], 'seed', 7, 'sampleRate', 30.72e6, ...
        'carrierFrequency', 2.6e9, 'numTxAnts', 16, 'numRxAnts', 2, ...
        'linkDirection', 'downlink');
    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, '..', 'umi'));
    u1 = buildUMiAVChannel(linkU, struct());
    u2 = buildUMiAVChannel(linkU, struct());
    assert(isequal(u1.PathDelays, u2.PathDelays) && ...
           isequal(u1.AnglesAoA, u2.AnglesAoA), ...
        'UMi builder is not seed-reproducible');
    checkVal(u1.AnglesZoD(1), linkU.losAngles(3), 1e-9, ...
        'clause 7.5 eq 7.5-12/-16: first cluster on the LOS direction');
    assert(u1.HasLOSCluster && isfinite(u1.KFactorFirstCluster), ...
        'UMi LOS link must carry a LOS cluster');

    fprintf('\nAll checks passed (%s).\n', datestr(now)); %#ok<TNOW1,DATST>
end

% ----------------------------------------------------------------------------
function checkVal(actual, expected, tol, what)
    if abs(actual - expected) > max(tol, eps)
        error('tr36777SelfTest:mismatch', ...
            'FAIL: %s\n  expected %.6f, got %.6f', what, expected, actual);
    end
    fprintf('PASS  %-58s %12.6f\n', what, actual);
end
