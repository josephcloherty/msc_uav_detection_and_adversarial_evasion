function [channels, linkInfo] = createScenarioChannels(cfg, gNBs, UEs)
% builds the per-link CDL channel matrix plus the linkInfo struct of LOS states,
% shadow fading and spatially-consistent fields that pathloss needs at run time.

    numUEs   = numel(UEs);
    numNodes = numel(gNBs) + numUEs;
    channels = cell(numNodes, numNodes);

    losStream = RandStream('Threefry', 'Seed', cfg.seed);
    linkInfo = struct();
    linkInfo.los = false(numNodes, numNodes);   % per link
    linkInfo.sf  = zeros(numNodes, numNodes);   % shadow fading

    % map gNB id to field index
    linkInfo.gnbIDs = [gNBs.ID];
    linkInfo.gnbIdxByID = zeros(1, max([gNBs.ID, UEs.ID]));
    for i = 1:numel(gNBs)
        linkInfo.gnbIdxByID(gNBs(i).ID) = i;
    end

    % build the spatially-consistent fields, TR 38.901 clause 7.6.3.1.
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
        % high substreams avoid collisions
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
            d2D = max(norm(dxy), 1);            % avoid log10(0)
            d3D = max(norm(uPos - gPos), 1);
            hUT = uPos(3);
            hBS = gPos(3);

            % draw the LOS state at t = 0, from the field when active
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

            % optional lognormal shadow fading, same source as the state
            if isfield(cfg, 'enableShadowFading') && cfg.enableShadowFading
                sigma = tr36777ShadowFadingStd(cfg.scenario, isLOS, hUT, ...
                    cfg.zBoundary);
                if dynamicLOS
                    if isLOS, whichSF = 1; else, whichSF = 2; end
                    [~, zSF] = sampleSpatialField(linkInfo.sfField{whichSF}, ...
                        i, uPos(1), uPos(2));
                    sfDB = sigma * zSF;
                else
                    % stream is already positioned
                    sfDB = sigma * randn(losStream);
                end
                linkInfo.sf(gNBs(i).ID, UEs(u).ID) = sfDB;
                linkInfo.sf(UEs(u).ID, gNBs(i).ID) = sfDB;
            end

            % geometric LOS angles, downlink convention
            aod = atan2d(dxy(2), dxy(1));                 % gNB to UE
            aoa = wrapTo180(aod + 180);                   % UE to gNB
            zod = acosd((hUT - hBS) / d3D);               % from zenith
            zoa = acosd((hBS - hUT) / d3D);

            aerialBand = hUT > cfg.zBoundary;
            if aerialBand && isfield(cfg, 'aerialChannelBuilder') ...
                    && ~isempty(cfg.aerialChannelBuilder)
                % fork-specific builder, one channel per direction
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
                % ZOD offset per Annex B.1.1 Step 5, LOS only
                if isLOS
                    switch upper(string(cfg.scenario))
                        case "RMA"   % ground reflection
                            zodOff = atand((hBS + hUT)/d2D) + ...
                                     atand((hUT - hBS)/d2D);
                        case "UMA"   % rooftop reflection
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
                    av = cfg.av.los;    % LOS row
                else
                    av = cfg.av.nlos;   % NLOS row
                end

                base = struct('isLOS', isLOS, ...
                    'desiredK_dB', av.K_dB, 'desiredDS_s', av.DS_s, ...
                    'zodOffsetDeg', zodOff, ...
                    'carrierFrequency', cfg.carrierFrequency, ...
                    'sampleRate', sampleRate);

                % uplink object: Tx is the UE, so angles and spreads mirror
                ul = base;
                ul.desiredAS = [av.ASA av.ASD av.ZSA av.ZSD];
                ul.losAngles = [aoa aod zoa zod];
                ul.offsetDim = 'ZoA';
                ul.seed = cfg.seed*1000 + linkIdx;
                ul.numTxAnts = UEs(u).NumTransmitAntennas;
                ul.numRxAnts = gNBs(i).NumReceiveAntennas;
                ul.linkDirection = 'uplink';
                channels{UEs(u).ID, gNBs(i).ID} = buildAerialCDL(ul);

                % downlink object: Tx is the gNB
                dl = base;
                dl.desiredAS = [av.ASD av.ASA av.ZSD av.ZSA];
                dl.losAngles = [aod aoa zod zoa];
                dl.offsetDim = 'ZoD';
                dl.seed = cfg.seed*1000 + linkIdx;
                dl.numTxAnts = gNBs(i).NumTransmitAntennas;
                dl.numRxAnts = UEs(u).NumReceiveAntennas;
                dl.linkDirection = 'downlink';
                channels{gNBs(i).ID, UEs(u).ID} = buildAerialCDL(dl);
            else
                % terrestrial band: built-in CDL profile
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

% ----------------------------------------------------------------------------
function extent = fieldExtent(cfg, gNBs, UEs)
% returns the horizontal area the spatially-consistent fields must cover, as the
% union of gNB positions, initial UE positions and both mobility-bound readings.
    pts = [reshape([gNBs.Position], 3, []).'; reshape([UEs.Position], 3, []).'];
    xs = pts(:,1); ys = pts(:,2);

    for f = {'aerialBounds', 'terrestrialBounds'}
        if ~isfield(cfg, f{1}) || numel(cfg.(f{1})) ~= 4, continue; end
        b = cfg.(f{1});
        % centre convention
        xs = [xs; b(1) - b(3)/2; b(1) + b(3)/2];   %#ok<AGROW>
        ys = [ys; b(2) - b(4)/2; b(2) + b(4)/2];   %#ok<AGROW>
        % corner convention
        xs = [xs; b(1); b(1) + b(3)];              %#ok<AGROW>
        ys = [ys; b(2); b(2) + b(4)];              %#ok<AGROW>
    end

    extent = [min(xs), max(xs), min(ys), max(ys)];
end

% ----------------------------------------------------------------------------
function d = losCorrelationDistance(cfg)
% returns the LOS state correlation distance from TR 38.901 Table 7.6.3.1-2.
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

% ----------------------------------------------------------------------------
function [dLOS, dNLOS] = sfCorrelationDistance(cfg)
% returns the shadow-fading correlation distances from TR 38.901 Table 7.6.3.1-2.
    switch upper(string(cfg.scenario))
        case "UMA", dLOS = 37;  dNLOS = 50;
        case "UMI", dLOS = 10;  dNLOS = 13;
        case "RMA", dLOS = 37;  dNLOS = 120;
        otherwise
            error('createScenarioChannels:badScenario', ...
                'Scenario must be UMa, RMa, or UMi.');
    end
end

% ----------------------------------------------------------------------------
function ds = terrestrialDelaySpread(scenario, isLOS, fcGHz)
% returns the median RMS delay spread from TR 38.901 Table 7.5-6 at the given
% carrier frequency.
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

% ----------------------------------------------------------------------------
function w = wrapTo180(a)
% wraps angles in degrees to (-180, 180], so the Mapping Toolbox is not needed.
    w = mod(a + 180, 360) - 180;
    w(w == -180) = 180;
end
