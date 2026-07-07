function validateUMiOverlay()
%validateUMiOverlay Before/after evidence figure for the UMi fork (D3.4).
%
%   Produces the validation figure comparing the terrestrial TR 38.901
%   UMi - Street Canyon model ("before": aerial overlay NOT applied) with
%   the TR 36.777 UMi-AV overlay ("after") for an aerial UE:
%
%     Panel 1: pathloss vs 2D distance at hUT = 100 m (LOS and NLOS);
%              before: nrPathLoss UMi, after: Table B-2 UMi-AV.
%     Panel 2: LOS probability vs distance at three heights;
%              before: Table 7.4.2-1 UMi, after: Table B-1 UMi-AV.
%     Panel 3: departure vs arrival azimuth spread of the generated
%              clause 7.5 clusters, standard UMi ("before") vs the
%              reverse-UMa interchange ("after"), same seed. The
%              interchange shows as the two markers swapping across the
%              diagonal: the aerial UE end takes the wide street-canyon
%              spread and the below-rooftop BS end the narrow one.
%     Panel 4: power delay profile of the same two realisations.
%
%   Saved to <Phase 3>/figures/validation_UMi.png / .fig. Run with the
%   core folder on the path (this script adds it itself).

    addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'core'));

    fcGHz = 2.6;  fcHz = fcGHz*1e9;
    hBS = 10;  hUT = 100;

    plc = nrPathLossConfig;
    plc.Scenario = 'UMi';
    plc.EnvironmentHeight = 1;

    fig = figure('Name', 'Aerial overlay validation: UMi', ...
        'Position', [80 80 1150 780], 'Color', 'w');

    % ---- Panel 1: pathloss ---------------------------------------------
    d2D = logspace(log10(20), log10(2000), 120);
    [plTerrL, plTerrN, plAvL, plAvN] = deal(zeros(size(d2D)));
    for k = 1:numel(d2D)
        d3D = hypot(d2D(k), hUT - hBS);
        bs = [0; 0; hBS];  ue = [d2D(k); 0; hUT];
        plTerrL(k) = nrPathLoss(plc, fcHz, 1, bs, ue);
        plTerrN(k) = nrPathLoss(plc, fcHz, 0, bs, ue);
        plAvL(k) = tr36777AerialPathloss('UMi', true,  fcGHz, hUT, d3D);
        plAvN(k) = tr36777AerialPathloss('UMi', false, fcGHz, hUT, d3D);
    end
    subplot(2,2,1); hold on; grid on;
    plot(d2D, plTerrL, 'b--', d2D, plTerrN, 'r--', 'LineWidth', 1.2);
    plot(d2D, plAvL, 'b-', d2D, plAvN, 'r-', 'LineWidth', 1.6);
    set(gca, 'XScale', 'log');
    xlabel('d_{2D} (m)'); ylabel('Pathloss (dB)');
    title(sprintf('UMi pathloss at h_{UT} = %g m', hUT));
    legend({'38.901 LOS (before)','38.901 NLOS (before)', ...
        '36.777 AV LOS (after)','36.777 AV NLOS (after)'}, 'Location','southeast');

    % ---- Panel 2: LOS probability ----------------------------------------
    subplot(2,2,2); hold on; grid on;
    heights = [30 60 100];
    cols = lines(numel(heights));
    for hh = 1:numel(heights)
        h = heights(hh);
        pTerr = arrayfun(@(d) umiTerrestrialLOS(d), d2D);
        pAv   = arrayfun(@(d) tr36777LOSProbability('UMi', h, d), d2D);
        plot(d2D, pTerr, '--', 'Color', cols(hh,:), 'LineWidth', 1.2);
        plot(d2D, pAv, '-', 'Color', cols(hh,:), 'LineWidth', 1.6, ...
            'DisplayName', sprintf('h_{UT} = %g m', h));
    end
    set(gca, 'XScale', 'log'); ylim([0 1.05]);
    xlabel('d_{2D} (m)'); ylabel('P_{LOS}');
    title('UMi LOS probability (dashed: 38.901 before, solid: 36.777 after)');

    % ---- Panels 3-4: reverse-UMa fast fading ------------------------------
    % Build the same LOS link twice with the same seed: once with the
    % standard UMi spreads (before) and once with the interchange (after).
    % The "before" realisation is obtained by swapping the LOS angles and
    % antenna ends instead, which reproduces the un-swapped spread
    % assignment with identical random draws.
    d2Dlink = 150;
    d3Dlink = hypot(d2Dlink, hUT - hBS);
    aod = 0; aoa = 180;
    zod = acosd((hUT - hBS)/d3Dlink);
    zoa = acosd((hBS - hUT)/d3Dlink);
    link = struct('isLOS', true, 'd2D', d2Dlink, 'd3D', d3Dlink, ...
        'hBS', hBS, 'hUT', hUT, 'losAngles', [aod aoa zod zoa], ...
        'seed', 7, 'sampleRate', 30.72e6, 'carrierFrequency', fcHz, ...
        'numTxAnts', 16, 'numRxAnts', 2, 'linkDirection', 'downlink');

    chAfter = buildUMiAVChannel(link, struct());        % interchanged (after)
    chBefore = buildUMiAVStandard(link);                % standard UMi (before)

    subplot(2,2,3); hold on; grid on;
    asB = powerWeightedSpread(chBefore);
    asA = powerWeightedSpread(chAfter);
    plot(asB.asd, asB.asa, 'bs', 'MarkerSize', 11, 'MarkerFaceColor', 'b');
    plot(asA.asd, asA.asa, 'ro', 'MarkerSize', 11, 'MarkerFaceColor', 'r');
    lim = max([asB.asd asB.asa asA.asd asA.asa]) * 1.15;
    plot([0 lim], [0 lim], 'k:');
    xlabel('Cluster azimuth spread, departure side (deg)');
    ylabel('Cluster azimuth spread, arrival side (deg)');
    title('Reverse-UMa interchange: spreads swap across the diagonal');
    legend({'standard UMi (before)','UMi-AV interchanged (after)'}, ...
        'Location', 'northwest');

    subplot(2,2,4); hold on; grid on;
    stem(chBefore.PathDelays*1e9, chBefore.AveragePathGains, 'b--o', ...
        'filled', 'MarkerSize', 4);
    stem(chAfter.PathDelays*1e9, chAfter.AveragePathGains, 'r-o', ...
        'filled', 'MarkerSize', 4);
    xlabel('Delay (ns)'); ylabel('Cluster power (dB)');
    title('PDP, same seed (delays/powers unchanged by the interchange)');
    legend({'before','after'}, 'Location', 'northeast');

    sgtitle(['UMi fork: TR 38.901 terrestrial (before) vs TR 36.777 ' ...
        'UMi-AV overlay (after), boundary 22.5 m']);

    outDir = fullfile(fileparts(mfilename('fullpath')), '..', 'figures');
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    exportgraphics(fig, fullfile(outDir, 'validation_UMi.png'), 'Resolution', 200);
    savefig(fig, fullfile(outDir, 'validation_UMi.fig'));
    fprintf('Validation figure saved to %s\n', outDir);
end

% ----------------------------------------------------------------------------
function ch = buildUMiAVStandard(link)
%buildUMiAVStandard Standard (un-swapped) UMi clause 7.5 realisation.
%   Used only as the "before" reference in this figure. Reuses
%   buildUMiAVChannel by exploiting that the interchange is an involution:
%   swapping the departure/arrival roles of the inputs and swapping them
%   back on the output object is equivalent to not interchanging at all.
    l2 = link;
    l2.losAngles = link.losAngles([2 1 4 3]);
    ch0 = buildUMiAVChannel(l2, struct());
    ch = nrCDLChannel;
    ch.DelayProfile     = 'Custom';
    ch.PathDelays       = ch0.PathDelays;
    ch.AveragePathGains = ch0.AveragePathGains;
    ch.AnglesAoD        = ch0.AnglesAoA;
    ch.AnglesAoA        = ch0.AnglesAoD;
    ch.AnglesZoD        = ch0.AnglesZoA;
    ch.AnglesZoA        = ch0.AnglesZoD;
    if ch0.HasLOSCluster
        ch.HasLOSCluster = true;
        ch.KFactorFirstCluster = ch0.KFactorFirstCluster;
    end
    ch.AngleSpreads     = ch0.AngleSpreads([2 1 4 3]);
    ch.XPR              = ch0.XPR;
    ch.CarrierFrequency = ch0.CarrierFrequency;
    ch.SampleRate       = ch0.SampleRate;
    ch.Seed             = ch0.Seed;
    ch.ChannelFiltering = false;
end

function s = powerWeightedSpread(ch)
%powerWeightedSpread Power-weighted rms azimuth spread of the cluster
% centre angles, departure and arrival sides.
    p = 10.^(ch.AveragePathGains/10);
    w = p / sum(p);
    s.asd = circSpread(ch.AnglesAoD, w);
    s.asa = circSpread(ch.AnglesAoA, w);
end

function as = circSpread(angDeg, w)
    mu = rad2deg(angle(sum(w .* exp(1i*deg2rad(angDeg)))));
    d = wrapTo180(angDeg - mu);
    as = sqrt(sum(w .* d.^2));
end

function p = umiTerrestrialLOS(d2D)
%umiTerrestrialLOS TR 38.901 Table 7.4.2-1, UMi - Street Canyon.
    if d2D <= 18
        p = 1;
    else
        p = 18/d2D + exp(-d2D/36)*(1 - 18/d2D);
    end
end

% ----------------------------------------------------------------------------
function w = wrapTo180(a)
%wrapTo180 Wrap angles in degrees to (-180, 180]. Local shadow of the
% Mapping Toolbox function so that toolbox is not a dependency.
    w = mod(a + 180, 360) - 180;
    w(w == -180) = 180;
end
