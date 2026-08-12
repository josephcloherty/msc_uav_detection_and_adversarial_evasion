function [channels, linkInfo] = createScenarioChannels(cfg, gNBs, UEs)
%createScenarioChannels Build the per-link CDL matrix with the TR 36.777 overlay.
%
%   [CHANNELS, LINKINFO] = createScenarioChannels(CFG, GNBS, UES) returns
%   the N-by-N cell matrix of nrCDLChannel objects consumed by
%   tr36777ChannelModel, plus LINKINFO carrying the per-link LOS states
%   and shadow-fading terms needed for pathloss at run time.
%
%   Per link (gNB-UE pair, one uplink and one downlink object):
%     1. Geometry from the initial node positions (d2D, d3D, hUT, LOS
%        angles). The CDL objects are static for the whole run; mobility
%        affects pathloss but not the fast-fading geometry. In the
%        deviations log.
%     2. LOS state drawn once from tr36777LOSProbability (TR 36.777
%        Table B-1 / TR 38.901 Table 7.4.2-1) on a dedicated Threefry stream,
%        one substream per link. This setup-time state picks the fast-fading
%        profile and is frozen with the CDL objects.
%     3. Fast fading:
%        - hUT > cfg.zBoundary (aerial band): TR 36.777 Annex B.1.1
%          Alternative 1 via buildAerialCDL, with the Table B.1.1-1/-2
%          desired parameters from cfg.av (set by the scenario script)
%          and the Step 5 ZOD offset in LOS.
%        - hUT <= cfg.zBoundary (terrestrial band, including aerial-class
%          UEs below the floor): built-in CDL-D (LOS) or CDL-C (NLOS)
%          scaled to the scenario median delay spread from TR 38.901
%          Table 7.5-6 at the carrier frequency.
%     4. Channel seeds are cfg.seed*1000 + a unique link index, so a
%        fixed cfg.seed regenerates every channel identically.
%
%   The state used for PATHLOSS is not frozen: LINKINFO also carries
%   spatially-consistent fields, one per gNB for LOS and two for shadow
%   fading, which linkState samples at the live UE position. Set
%   cfg.dynamicLOS = false for the Phase 4 frozen behaviour.
%
%   ZOD offset geometry (Annex B.1.1 Step 5, verified equations):
%     RMa-AV (B.1.1-1): mu = arctan((hBS+hUT)/d2D) + arctan((hUT-hBS)/d2D)
%                       (specular reflection on the GROUND)
%     UMa-AV (B.1.1-2): mu = arctan((hBS+hUT-2h)/d2D) + arctan((hUT-hBS)/d2D)
%                       (specular reflection on the building ROOF, h =
%                       building height, cfg.avgBuildingHeight)
%     NLOS (Step 6):    mu = 0.

    numUEs   = numel(UEs);
    numNodes = numel(gNBs) + numUEs;
    channels = cell(numNodes, numNodes);

    losStream = RandStream('Threefry', 'Seed', cfg.seed);
    linkInfo = struct();
    linkInfo.los = false(numNodes, numNodes);   % indexed [gNB.ID, UE.ID]
    linkInfo.sf  = zeros(numNodes, numNodes);   % shadow fading (dB)

    % Maps gNB ID to field index, so linkState does not search per packet.
    linkInfo.gnbIDs = [gNBs.ID];
    linkInfo.gnbIdxByID = zeros(1, max([gNBs.ID, UEs.ID]));
    for i = 1:numel(gNBs)
        linkInfo.gnbIdxByID(gNBs(i).ID) = i;
    end

    % TR 38.901 clause 7.6.3.1.
    dynamicLOS = ~isfield(cfg, 'dynamicLOS') || cfg.dynamicLOS;
    linkInfo.dynamicLOS = dynamicLOS;
    linkInfo.losField = [];
    linkInfo.sfField  = {};
    if dynamicLOS
        extent = fieldExtent(cfg, gNBs, UEs);
        dcorLOS = losCorrelationDistance(cfg);
        [dcorSFLOS, dcorSFNLOS] = sfCorrelationDistance(cfg);
        linkInfo.extent  = extent;
        linkInfo.dcorLOS = dcorLOS;
        % Substreams from 10^6 up, so they cannot collide with the per-link
        % ones used below.
        linkInfo.losField   = buildSpatialField(cfg.seed, 1000001, ...
            numel(gNBs), extent, dcorLOS);
        linkInfo.sfField{1} = buildSpatialField(cfg.seed, 1000002, ...
            numel(gNBs), extent, dcorSFLOS);
        linkInfo.sfField{2} = buildSpatialField(cfg.seed, 1000003, ...
            numel(gNBs), extent, dcorSFNLOS);
    end

    fcGHz = cfg.carrierFrequency / 1e9;
    linkIdx = 0;

    for i = 1:numel(gNBs)
        waveformInfo = nrOFDMInfo(gNBs(i).NumResourceBlocks, ...
            gNBs(i).SubcarrierSpacing/1e3);
        sampleRate = waveformInfo.SampleRate;
        gPos = gNBs(i).Position;

        for u = 1:numUEs
            linkIdx = linkIdx + 1;
            uPos = UEs(u).Position;

            dxy = uPos(1:2) - gPos(1:2);
            d2D = max(norm(dxy), 1);            % avoid log10(0) pathologies
            d3D = max(norm(uPos - gPos), 1);
            hUT = uPos(3);
            hBS = gPos(3);

            % Shared by the UL and DL objects, and read from the field when
            % active so a link cannot start CDL-D while pathloss says NLOS.
            pLOS = tr36777LOSProbability(cfg.scenario, hUT, d2D);
            if dynamicLOS
                uLOS  = sampleSpatialField(linkInfo.losField, i, ...
                    uPos(1), uPos(2));
                isLOS = uLOS < pLOS;
            else
                losStream.Substream = linkIdx;
                isLOS = rand(losStream) < pLOS;
            end
            linkInfo.los(gNBs(i).ID, UEs(u).ID) = isLOS;
            linkInfo.los(UEs(u).ID, gNBs(i).ID) = isLOS;

            % Sampled at t = 0 from the same process linkState evaluates at
            % run time.
            if isfield(cfg, 'enableShadowFading') && cfg.enableShadowFading
                sigma = tr36777ShadowFadingStd(cfg.scenario, isLOS, hUT, ...
                    cfg.zBoundary);
                if dynamicLOS
                    if isLOS, whichSF = 1; else, whichSF = 2; end
                    [~, zSF] = sampleSpatialField(linkInfo.sfField{whichSF}, ...
                        i, uPos(1), uPos(2));
                    sfDB = sigma * zSF;
                else
                    % The stream already sits just after this link's isLOS
                    % draw, so the substream must not be reset here.
                    sfDB = sigma * randn(losStream);
                end
                linkInfo.sf(gNBs(i).ID, UEs(u).ID) = sfDB;
                linkInfo.sf(UEs(u).ID, gNBs(i).ID) = sfDB;
            end

            % Downlink convention, Tx = gNB.
            aod = atan2d(dxy(2), dxy(1));                 % gNB -> UE azimuth
            aoa = wrapTo180(aod + 180);                   % UE -> gNB azimuth
            zod = acosd((hUT - hBS) / d3D);               % from zenith
            zoa = acosd((hBS - hUT) / d3D);

            aerialBand = hUT > cfg.zBoundary;
            if aerialBand && isfield(cfg, 'aerialChannelBuilder') ...
                    && ~isempty(cfg.aerialChannelBuilder)
                % UMi's Alternative 1 is not CDL-D based, so it supplies its
                % own builder, one channel per direction.
                g = struct('isLOS', isLOS, 'd2D', d2D, 'd3D', d3D, ...
                    'hBS', hBS, 'hUT', hUT, ...
                    'carrierFrequency', cfg.carrierFrequency, ...
                    'sampleRate', sampleRate);

                ul = g;
                ul.losAngles = [aoa aod zoa zod];
                ul.seed = cfg.seed*1000 + linkIdx;
                ul.numTxAnts = UEs(u).NumTransmitAntennas;
                ul.numRxAnts = gNBs(i).NumReceiveAntennas;
                ul.linkDirection = 'uplink';
                channels{UEs(u).ID, gNBs(i).ID} = cfg.aerialChannelBuilder(ul, cfg);

                dl = g;
                dl.losAngles = [aod aoa zod zoa];
                dl.seed = cfg.seed*1000 + linkIdx;
                dl.numTxAnts = gNBs(i).NumTransmitAntennas;
                dl.numRxAnts = UEs(u).NumReceiveAntennas;
                dl.linkDirection = 'downlink';
                channels{gNBs(i).ID, UEs(u).ID} = cfg.aerialChannelBuilder(dl, cfg);
            elseif aerialBand
                % ZOD offset per Annex B.1.1 Step 5, LOS only.
                if isLOS
                    switch upper(string(cfg.scenario))
                        case "RMA"   % eq B.1.1-1, ground reflection
                            zodOff = atand((hBS + hUT)/d2D) + ...
                                     atand((hUT - hBS)/d2D);
                        case "UMA"   % eq B.1.1-2, rooftop reflection
                            h = cfg.avgBuildingHeight;
                            zodOff = atand((hBS + hUT - 2*h)/d2D) + ...
                                     atand((hUT - hBS)/d2D);
                        otherwise
                            error('createScenarioChannels:umiNeedsBuilder', ...
                                ['UMi-AV Alternative 1 is not CDL-D based ' ...
                                 '(TR 36.777 Annex B.1.1, final paragraph). ' ...
                                 'Use the UMi fork script, which supplies ' ...
                                 'cfg.aerialChannelBuilder.']);
                    end
                else
                    zodOff = 0;
                end

                if isLOS
                    av = cfg.av.los;    % Table B.1.1-1/-2 LOS row
                else
                    av = cfg.av.nlos;   % Table B.1.1-1/-2 NLOS row
                end

                base = struct('isLOS', isLOS, ...
                    'desiredK_dB', av.K_dB, 'desiredDS_s', av.DS_s, ...
                    'zodOffsetDeg', zodOff, ...
                    'carrierFrequency', cfg.carrierFrequency, ...
                    'sampleRate', sampleRate);

                % Tx = UE, so the BS-side zenith dimension becomes ZoA.
                ul = base;
                ul.desiredAS = [av.ASA av.ASD av.ZSA av.ZSD];
                ul.losAngles = [aoa aod zoa zod];
                ul.offsetDim = 'ZoA';
                ul.seed = cfg.seed*1000 + linkIdx;
                ul.numTxAnts = UEs(u).NumTransmitAntennas;
                ul.numRxAnts = gNBs(i).NumReceiveAntennas;
                ul.linkDirection = 'uplink';
                channels{UEs(u).ID, gNBs(i).ID} = buildAerialCDL(ul);

                dl = base;   % Tx = gNB
                dl.desiredAS = [av.ASD av.ASA av.ZSD av.ZSA];
                dl.losAngles = [aod aoa zod zoa];
                dl.offsetDim = 'ZoD';
                dl.seed = cfg.seed*1000 + linkIdx;
                dl.numTxAnts = gNBs(i).NumTransmitAntennas;
                dl.numRxAnts = UEs(u).NumReceiveAntennas;
                dl.linkDirection = 'downlink';
                channels{gNBs(i).ID, UEs(u).ID} = buildAerialCDL(dl);
            else
                % Built-in CDL profile at the scenario median delay spread
                % from Table 7.5-6.
                if isLOS
                    profile = 'CDL-D';
                else
                    profile = 'CDL-C';
                end
                ds = terrestrialDelaySpread(cfg.scenario, isLOS, fcGHz);

                ulCh = nrCDLChannel;
                ulCh.DelayProfile = profile;
                ulCh.DelaySpread = ds;
                ulCh.CarrierFrequency = cfg.carrierFrequency;
                ulCh.SampleRate = sampleRate;
                ulCh.Seed = cfg.seed*1000 + linkIdx;
                ulCh.ChannelFiltering = false;
                ulCh = hArrayGeometry(ulCh, UEs(u).NumTransmitAntennas, ...
                    gNBs(i).NumReceiveAntennas, 'uplink');
                channels{UEs(u).ID, gNBs(i).ID} = ulCh;

                dlCh = nrCDLChannel;
                dlCh.DelayProfile = profile;
                dlCh.DelaySpread = ds;
                dlCh.CarrierFrequency = cfg.carrierFrequency;
                dlCh.SampleRate = sampleRate;
                dlCh.Seed = cfg.seed*1000 + linkIdx;
                dlCh.ChannelFiltering = false;
                dlCh = hArrayGeometry(dlCh, gNBs(i).NumTransmitAntennas, ...
                    UEs(u).NumReceiveAntennas, 'downlink');
                channels{gNBs(i).ID, UEs(u).ID} = dlCh;
            end
        end
    end
end

function extent = fieldExtent(cfg, gNBs, UEs)
%fieldExtent Horizontal area the spatially-consistent fields must cover.
%   Union of the gNB positions, the initial UE positions, and the mobility
%   bounds read BOTH ways, because cfg.aerialBounds does not record which
%   convention produced it. The union costs only a slightly larger grid and
%   removes any chance of a UE walking off the field.
    pts = [reshape([gNBs.Position], 3, []).'; reshape([UEs.Position], 3, []).'];
    xs = pts(:,1); ys = pts(:,2);

    for f = {'aerialBounds', 'terrestrialBounds'}
        if ~isfield(cfg, f{1}) || numel(cfg.(f{1})) ~= 4, continue; end
        b = cfg.(f{1});
        % centre convention: [xCentre yCentre width height]
        xs = [xs; b(1) - b(3)/2; b(1) + b(3)/2];   %#ok<AGROW>
        ys = [ys; b(2) - b(4)/2; b(2) + b(4)/2];   %#ok<AGROW>
        % corner convention: [xMin yMin width height]
        xs = [xs; b(1); b(1) + b(3)];              %#ok<AGROW>
        ys = [ys; b(2); b(2) + b(4)];              %#ok<AGROW>
    end

    extent = [min(xs), max(xs), min(ys), max(ys)];
end

function d = losCorrelationDistance(cfg)
%losCorrelationDistance LOS/NLOS state correlation distance.
%   TR 38.901 Table 7.6.3.1-2 ("Correlation distance for spatial
%   consistency"), LOS/NLOS state row. Overridable via
%   cfg.losCorrelationDistance_m for a sensitivity study.
    if isfield(cfg, 'losCorrelationDistance_m') ...
            && ~isempty(cfg.losCorrelationDistance_m)
        d = cfg.losCorrelationDistance_m;
        return;
    end
    switch upper(string(cfg.scenario))
        case "UMA", d = 50;
        case "UMI", d = 50;
        case "RMA", d = 60;
        otherwise
            error('createScenarioChannels:badScenario', ...
                'Scenario must be UMa, RMa, or UMi.');
    end
end

function [dLOS, dNLOS] = sfCorrelationDistance(cfg)
%sfCorrelationDistance Shadow-fading correlation distances.
%   TR 38.901 Table 7.6.3.1-2, SF row, per scenario and LOS branch.
    switch upper(string(cfg.scenario))
        case "UMA", dLOS = 37;  dNLOS = 50;
        case "UMI", dLOS = 10;  dNLOS = 13;
        case "RMA", dLOS = 37;  dNLOS = 120;
        otherwise
            error('createScenarioChannels:badScenario', ...
                'Scenario must be UMa, RMa, or UMi.');
    end
end

function ds = terrestrialDelaySpread(scenario, isLOS, fcGHz)
%terrestrialDelaySpread Median RMS delay spread, TR 38.901 Table 7.5-6.
%   Values are the mu_lgDS entries of the provided 38901-j40 source
%   document (Part-1 for UMi/UMa, Part-2 for RMa), evaluated at the
%   carrier frequency. DS = 10^mu_lgDS seconds.
    switch upper(string(scenario))
        case "UMA"
            if isLOS, mu = -7.067 - 0.0794*log10(fcGHz);
            else,     mu = -6.47  - 0.134 *log10(fcGHz);
            end
        case "RMA"
            if isLOS, mu = -7.49;
            else,     mu = -7.43;
            end
        case "UMI"
            if isLOS, mu = -0.18*log10(1 + fcGHz) - 7.28;
            else,     mu = -0.22*log10(1 + fcGHz) - 6.87;
            end
        otherwise
            error('createScenarioChannels:badScenario', ...
                'Scenario must be UMa, RMa, or UMi.');
    end
    ds = 10^mu;
end

function w = wrapTo180(a)
%wrapTo180 Wrap angles in degrees to (-180, 180].
%   Local shadow of the Mapping Toolbox function, which is not a dependency.
    w = mod(a + 180, 360) - 180;
    w(w == -180) = 180;
end
