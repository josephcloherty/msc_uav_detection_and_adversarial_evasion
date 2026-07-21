function validateAerialOverlay(scenario)
%validateAerialOverlay Before/after evidence figure for an aerial fork (D3.2/D3.3).
%
%   validateAerialOverlay(SCENARIO) produces the validation figure for the
%   given fork ('UMa' or 'RMa'): each panel compares the terrestrial
%   TR 38.901 model ("before", i.e. the aerial overlay NOT applied) with
%   the TR 36.777 aerial overlay ("after") for an aerial UE:
%
%     Panel 1: pathloss vs 2D distance at hUT = 100 m, LOS and NLOS.
%              Before: toolbox nrPathLoss (TR 38.901 scenario formula).
%              After:  tr36777AerialPathloss (Table B-2).
%     Panel 2: LOS probability vs 2D distance at three UE heights.
%              Before: TR 38.901 Table 7.4.2-1. After: Table B-1.
%     Panel 3: cluster power vs cluster ZOD for the fast-fading model of a
%              representative LOS link. Before: unscaled CDL-D
%              (Table 7.7.1-4). After: Annex B.1.1 Alternative 1 (angle
%              scaling to the Table B.1.1-x spreads about the LOS
%              direction, plus the Step 5 ZOD offset on non-direct paths).
%     Panel 4: power delay profile of the same link. Before: CDL-D at the
%              terrestrial median delay spread (Table 7.5-6). After:
%              CDL-D scaled to the desired 10 ns LOS delay spread with the
%              K-factor scaled to 20 dB.
%
%   The figure is saved to <Phase 3>/figures/validation_<scenario>.png and
%   .fig. No network simulation is needed; this runs in seconds.

    addpath(fullfile(fileparts(mfilename('fullpath')), 'functions'));
    scenario = upper(string(scenario));
    assert(any(scenario == ["UMA","RMA"]), ...
        'validateAerialOverlay:badScenario', ...
        'This validation covers the CDL-D based forks: UMa or RMa.');

    % Fork-specific settings (same sources as the scenario scripts)
    if scenario == "UMA"
        scenName = 'UMa';  hBS = 25;  zB = 22.5;
        avLOS  = struct('AS',[0.5 0.5 0.1 0.1],'K',20,'DS',10e-9);
        avNLOS = struct('AS',[1 1 0.3 0.3],    'K',10,'DS',30e-9);
        hBuild = 20;
        heights = [30 60 90];
    else
        scenName = 'RMa';  hBS = 35;  zB = 10;
        avLOS  = struct('AS',[0.2 0.2 0.1 0.1],'K',20,'DS',10e-9);
        avNLOS = struct('AS',[0.5 0.5 0.2 0.2],'K',10,'DS',30e-9);
        hBuild = NaN;   % ground reflection, no building term
        heights = [15 25 35];
    end
    fcGHz = 2.6;  fcHz = fcGHz*1e9;
    hUT = 100;

    plc = nrPathLossConfig;
    plc.Scenario = scenName;
    if scenName == "UMa", plc.EnvironmentHeight = 1; end

    fig = figure('Name', "Aerial overlay validation: " + scenName, ...
        'Position', [80 80 1150 780], 'Color', 'w');

    % ---- Panel 1: pathloss --------------------------------------------------
    d2D = logspace(log10(50), log10(4000), 120);
    [plTerrL, plTerrN, plAvL, plAvN] = deal(zeros(size(d2D)));
    for k = 1:numel(d2D)
        d3D = hypot(d2D(k), hUT - hBS);
        bs = [0; 0; hBS];  ue = [d2D(k); 0; hUT];
        plTerrL(k) = nrPathLoss(plc, fcHz, 1, bs, ue);
        plTerrN(k) = nrPathLoss(plc, fcHz, 0, bs, ue);
        plAvL(k) = tr36777AerialPathloss(scenName, true,  fcGHz, hUT, d3D);
        plAvN(k) = tr36777AerialPathloss(scenName, false, fcGHz, hUT, d3D);
    end
    subplot(2,2,1); hold on; grid on;
    plot(d2D, plTerrL, 'b--', 'LineWidth', 1.2);
    plot(d2D, plTerrN, 'r--', 'LineWidth', 1.2);
    plot(d2D, plAvL, 'b-', 'LineWidth', 1.6);
    plot(d2D, plAvN, 'r-', 'LineWidth', 1.6);
    set(gca, 'XScale', 'log');
    xlabel('d_{2D} (m)'); ylabel('Pathloss (dB)');
    title(sprintf('%s pathloss at h_{UT} = %g m', scenName, hUT));
    legend({'38.901 LOS (before)','38.901 NLOS (before)', ...
        '36.777 AV LOS (after)','36.777 AV NLOS (after)'}, 'Location','southeast');

    % ---- Panel 2: LOS probability -------------------------------------------
    subplot(2,2,2); hold on; grid on;
    cols = lines(numel(heights));
    for hh = 1:numel(heights)
        h = heights(hh);
        pTerr = arrayfun(@(d) terrestrialOnlyLOS(scenName, h, d), d2D);
        pAv   = arrayfun(@(d) tr36777LOSProbability(scenName, h, d), d2D);
        plot(d2D, pTerr, '--', 'Color', cols(hh,:), 'LineWidth', 1.2);
        plot(d2D, pAv,   '-',  'Color', cols(hh,:), 'LineWidth', 1.6, ...
            'DisplayName', sprintf('h_{UT} = %g m', h));
    end
    set(gca, 'XScale', 'log'); ylim([0 1.05]);
    xlabel('d_{2D} (m)'); ylabel('P_{LOS}');
    title(sprintf('%s LOS probability (dashed: 38.901 before, solid: 36.777 after)', scenName));

    % ---- Panels 3 and 4: fast fading, representative LOS link ---------------
    d2Dlink = 500;
    d3Dlink = hypot(d2Dlink, hUT - hBS);
    aod = 0; aoa = 180;
    zod = acosd((hUT - hBS)/d3Dlink);
    zoa = acosd((hBS - hUT)/d3Dlink);
    if scenario == "UMA"
        zodOff = atand((hBS + hUT - 2*hBuild)/d2Dlink) + atand((hUT - hBS)/d2Dlink);
    else
        zodOff = atand((hBS + hUT)/d2Dlink) + atand((hUT - hBS)/d2Dlink);
    end

    link = struct('isLOS', true, ...
        'desiredAS', avLOS.AS([2 1 4 3]), ...   % [ASD ASA ZSD ZSA] DL order
        'desiredK_dB', avLOS.K, 'desiredDS_s', avLOS.DS, ...
        'losAngles', [aod aoa zod zoa], 'zodOffsetDeg', zodOff, ...
        'offsetDim', 'ZoD', 'carrierFrequency', fcHz, ...
        'sampleRate', 30.72e6, 'seed', 1, ...
        'numTxAnts', 16, 'numRxAnts', 2, 'linkDirection', 'downlink');
    chAfter = buildAerialCDL(link);

    % Before: unscaled CDL-D table (Table 7.7.1-4) at the terrestrial
    % median LOS delay spread for the scenario.
    if scenario == "UMA"
        dsTerr = 10^(-7.067 - 0.0794*log10(fcGHz));
    else
        dsTerr = 10^(-7.49);
    end
    cdlD = [ 0        -13.5     0    -180     98.5   81.5
             0.035    -18.8    89.2    89.2   85.5   86.9
             0.612    -21      89.2    89.2   85.5   86.9
             1.363    -22.8    89.2    89.2   85.5   86.9
             1.405    -17.9    13     163     97.5   79.4
             1.804    -20.1    13     163     97.5   79.4
             2.596    -21.9    13     163     97.5   79.4
             1.775    -22.9    34.6  -137     98.5   78.2
             4.042    -27.8   -64.5    74.5   88.4   73.6
             7.937    -23.6   -32.9   127.7   91.3   78.3
             9.424    -24.8    52.6  -119.6  103.8   87
             9.708    -30.0  -132.1    -9.1   80.3   70.6
            12.525    -27.7    77.2   -83.8   86.5   72.9 ];

    subplot(2,2,3); hold on; grid on;
    stem(cdlD(:,5), cdlD(:,2), 'b--o', 'filled', 'MarkerSize', 4);
    stem(98.5, -0.2, 'b-s', 'filled', 'MarkerSize', 7);   % LOS ray (before)
    afterZoD = chAfter.AnglesZoD;
    afterP   = chAfter.AveragePathGains;
    stem(afterZoD(2:end), afterP(2:end), 'r--o', 'filled', 'MarkerSize', 4);
    stem(afterZoD(1), afterP(1), 'r-s', 'filled', 'MarkerSize', 7);
    xline(zod, 'k:', 'LOS direction');
    xline(zod + zodOff, 'r:', 'LOS + ZOD offset');
    xlabel('Cluster ZOD (deg)'); ylabel('Cluster power (dB)');
    title('Cluster ZOD: CDL-D table (blue, before) vs Alt-1 scaled + offset (red, after)');

    subplot(2,2,4); hold on; grid on;
    stem(cdlD(:,1)*dsTerr*1e9, cdlD(:,2), 'b--o', 'filled', 'MarkerSize', 4);
    stem(chAfter.PathDelays*1e9, afterP, 'r-o', 'filled', 'MarkerSize', 4);
    xlabel('Delay (ns)'); ylabel('Cluster power (dB)');
    title(sprintf(['PDP: terrestrial DS %.0f ns (before) vs desired DS %.0f ns, ' ...
        'K %.0f dB (after)'], dsTerr*1e9, avLOS.DS*1e9, avLOS.K));
    legend({'before (38.901 baseline)','after (36.777 Alt-1)'}, 'Location','northeast');

    sgtitle(sprintf(['%s fork: TR 38.901 terrestrial (before) vs TR 36.777 ' ...
        'aerial overlay (after), h_{UT} = %g m, boundary %.1f m'], ...
        scenName, hUT, zB));

    % ---- save ---------------------------------------------------------------
    outDir = fullfile(fileparts(mfilename('fullpath')), '..', 'figures');
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    exportgraphics(fig, fullfile(outDir, "validation_" + scenName + ".png"), ...
        'Resolution', 200);
    savefig(fig, fullfile(outDir, "validation_" + scenName + ".fig"));
    fprintf('Validation figure saved to %s\n', outDir);
end

% ----------------------------------------------------------------------------
function p = terrestrialOnlyLOS(scenario, hUT, d2D)
%terrestrialOnlyLOS TR 38.901 Table 7.4.2-1 formula applied regardless of
% height ("before" case: the aerial overlay not applied). For UMa the
% C'(hUT) term is defined up to 23 m and is held at its 23 m value above
% that, which is exactly what applying the terrestrial model out of range
% means.
    switch upper(string(scenario))
        case "RMA"
            if d2D <= 10, p = 1; else, p = exp(-(d2D-10)/1000); end
        case "UMA"
            if d2D <= 18
                p = 1;
            else
                if hUT <= 13, C = 0; else, C = ((min(hUT,23)-13)/10)^1.5; end
                p = (18/d2D + exp(-d2D/63)*(1-18/d2D)) * ...
                    (1 + C*(5/4)*(d2D/100)^3*exp(-d2D/150));
            end
        case "UMI"
            if d2D <= 18, p = 1; else, p = 18/d2D + exp(-d2D/36)*(1-18/d2D); end
    end
    p = min(max(p,0),1);
end
