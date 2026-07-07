function [channels, linkInfo] = createScenarioChannels(cfg, gNBs, UEs)
%createScenarioChannels Build the per-link CDL matrix with the TR 36.777 overlay.
%
%   [CHANNELS, LINKINFO] = createScenarioChannels(CFG, GNBS, UES) returns
%   the N-by-N cell matrix of nrCDLChannel objects consumed by
%   tr36777ChannelModel, plus LINKINFO carrying the per-link LOS states
%   and shadow-fading terms needed for pathloss at run time.
%
%   Per link (gNB-UE pair, one uplink and one downlink object):
%     1. Geometry from the INITIAL node positions (d2D, d3D, hUT, LOS
%        angles). The CDL objects are static for the whole run, matching
%        the Phase 2 behaviour; mobility affects pathloss (recomputed per
%        packet from live positions) but not the fast-fading geometry.
%        Recorded in the deviations log as a known simplification.
%     2. LOS state drawn once from tr36777LOSProbability (TR 36.777
%        Table B-1 / TR 38.901 Table 7.4.2-1) using a dedicated
%        Threefry RandStream seeded from cfg.seed with one substream per
%        link, so LOS draws are reproducible and independent of any other
%        rng consumption in the run.
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

            % --- LOS draw (one per gNB-UE pair; UL and DL share it) ------
            losStream.Substream = linkIdx;
            pLOS  = tr36777LOSProbability(cfg.scenario, hUT, d2D);
            isLOS = rand(losStream) < pLOS;
            linkInfo.los(gNBs(i).ID, UEs(u).ID) = isLOS;
            linkInfo.los(UEs(u).ID, gNBs(i).ID) = isLOS;

            % --- Optional lognormal shadow fading, drawn once per pair ---
            if isfield(cfg, 'enableShadowFading') && cfg.enableShadowFading
                sigma = tr36777ShadowFadingStd(cfg.scenario, isLOS, hUT, ...
                    cfg.zBoundary);
                sfDB = sigma * randn(losStream);
                linkInfo.sf(gNBs(i).ID, UEs(u).ID) = sfDB;
                linkInfo.sf(UEs(u).ID, gNBs(i).ID) = sfDB;
            end

            % --- LOS geometric angles (downlink convention: Tx = gNB) ----
            aod = atan2d(dxy(2), dxy(1));                 % gNB -> UE azimuth
            aoa = wrapTo180(aod + 180);                   % UE -> gNB azimuth
            zod = acosd((hUT - hBS) / d3D);               % from zenith
            zoa = acosd((hBS - hUT) / d3D);

            aerialBand = hUT > cfg.zBoundary;
            if aerialBand && isfield(cfg, 'aerialChannelBuilder') ...
                    && ~isempty(cfg.aerialChannelBuilder)
                % Fork-specific fast-fading builder (used by the UMi fork,
                % whose Alternative 1 is NOT CDL-D based; see deviations
                % log). The builder receives the link geometry and returns
                % one nrCDLChannel per direction.
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
                % ZOD offset per Annex B.1.1 Step 5 (LOS only; Step 6: 0)
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

                % Uplink object: Tx = UE, so departure-side quantities are
                % the UE side. Angles and desired spreads are mirrored;
                % the BS-side zenith dimension becomes ZoA.
                ul = base;
                ul.desiredAS = [av.ASA av.ASD av.ZSA av.ZSD];
                ul.losAngles = [aoa aod zoa zod];
                ul.offsetDim = 'ZoA';
                ul.seed = cfg.seed*1000 + linkIdx;
                ul.numTxAnts = UEs(u).NumTransmitAntennas;
                ul.numRxAnts = gNBs(i).NumReceiveAntennas;
                ul.linkDirection = 'uplink';
                channels{UEs(u).ID, gNBs(i).ID} = buildAerialCDL(ul);

                % Downlink object: Tx = gNB.
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
                % Terrestrial band: built-in CDL profile, scenario median
                % delay spread from TR 38.901 Table 7.5-6.
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

% ----------------------------------------------------------------------------
function w = wrapTo180(a)
%wrapTo180 Wrap angles in degrees to (-180, 180]. Local shadow of the
% Mapping Toolbox function so that toolbox is not a dependency.
    w = mod(a + 180, 360) - 180;
    w(w == -180) = 180;
end
