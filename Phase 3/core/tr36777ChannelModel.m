classdef tr36777ChannelModel
    %tr36777ChannelModel Height-aware pathloss + CDL channel model (Phase 3).
    %
    %   Adapted from the MathWorks helper hNRCustomChannelModel (Copyright
    %   2022-2023 The MathWorks, Inc.). The fast-fading application path
    %   (applyChannelModel's PathGains/PathFilters handling) is retained
    %   as-is; the pathloss computation is replaced by the TR 36.777 /
    %   TR 38.901 height-switched model:
    %
    %     - UE height (from the LIVE node positions of each packet) at or
    %       below cfg.zBoundary: terrestrial TR 38.901 pathloss for the
    %       configured scenario via the toolbox nrPathLoss.
    %     - UE height above cfg.zBoundary: TR 36.777 Table B-2 aerial
    %       pathloss via tr36777AerialPathloss.
    %
    %   Because the pathloss is recomputed from live positions per packet,
    %   an aerial UE that climbs through the z-boundary transitions from
    %   the terrestrial to the aerial pathloss model mid-run, as TR 36.777
    %   Annex B intends. The LOS state and (optional) shadow-fading term
    %   are drawn once per link at setup by createScenarioChannels and held
    %   fixed, consistent with the static per-link CDL objects.
    %
    %   The z-boundary is 22.5 m for UMa/UMi and 10 m for RMa (TR 36.777
    %   Annex B.1); it is supplied by the scenario script via cfg.

    properties (SetAccess=private)
        %PHYAbstractionMethod "linkToSystemMapping" (abstract PHY) or "none"
        PHYAbstractionMethod = "linkToSystemMapping"

        %Cfg Scenario configuration struct (scenario, zBoundary,
        % carrierFrequency, ...) from the scenario script
        Cfg

        %LinkInfo Per-link LOS states and shadow-fading terms
        % (from createScenarioChannels)
        LinkInfo

        %UENodeIDs IDs of the UE nodes (to find the UE end of each packet)
        UENodeIDs

        %NRPathLossConfig Terrestrial TR 38.901 pathloss configuration
        NRPathLossConfig

        %ChannelModelMatrix Matrix of channel models for the links
        ChannelModelMatrix

        %MaxChannelDelayMatrix Matrix of maximum channel delay for the links
        MaxChannelDelayMatrix

        %PathFilter Matrix of path filters for the links
        PathFilter
    end

    properties(Access=private)
        PHYAbstractionMethodNum
    end

    methods
        function obj = tr36777ChannelModel(channelModelMatrix, cfg, linkInfo, ueNodeIDs)
            % channelModelMatrix - N-by-N cell matrix from createScenarioChannels
            % cfg                - scenario config struct
            % linkInfo           - LOS / shadow-fading struct from createScenarioChannels
            % ueNodeIDs          - vector of UE node IDs

            obj.Cfg = cfg;
            obj.LinkInfo = linkInfo;
            obj.UENodeIDs = ueNodeIDs;
            if isfield(cfg, 'PHYAbstractionMethod')
                obj.PHYAbstractionMethod = cfg.PHYAbstractionMethod;
            end

            obj.NRPathLossConfig = nrPathLossConfig;
            switch upper(string(cfg.scenario))
                case "UMA", obj.NRPathLossConfig.Scenario = 'UMa';
                case "RMA", obj.NRPathLossConfig.Scenario = 'RMa';
                case "UMI", obj.NRPathLossConfig.Scenario = 'UMi';
                otherwise
                    error('tr36777ChannelModel:badScenario', ...
                        'Scenario must be UMa, RMa, or UMi.');
            end
            if any(strcmpi(obj.NRPathLossConfig.Scenario, {'UMa','UMi'}))
                obj.NRPathLossConfig.EnvironmentHeight = 1;
            end

            obj.PHYAbstractionMethodNum = ~strcmp(obj.PHYAbstractionMethod, "none");
            obj.ChannelModelMatrix = channelModelMatrix;
            obj.MaxChannelDelayMatrix = zeros(size(obj.ChannelModelMatrix));
            for i = 1:size(obj.ChannelModelMatrix,1)
                for j = 1:size(obj.ChannelModelMatrix,2)
                    if ~isempty(obj.ChannelModelMatrix{i,j})
                        chInfo = info(obj.ChannelModelMatrix{i,j});
                        obj.MaxChannelDelayMatrix(i,j) = ...
                            ceil(max(chInfo.PathDelays*obj.ChannelModelMatrix{i,j}.SampleRate)) ...
                            + chInfo.ChannelFilterDelay;
                        obj.PathFilter{i,j} = getPathFilters(obj.ChannelModelMatrix{i,j}).';
                    end
                end
            end
        end

        function outputData = applyChannelModel(obj, rxInfo, txData)
            %applyChannelModel Apply pathloss and fast fading to a packet.

            outputData = txData;

            % ---- Height-switched pathloss (TR 36.777 Annex B) -----------
            txPos = txData.TransmitterPosition(:).';
            rxPos = rxInfo.Position(:).';
            isLOS = obj.LinkInfo.los(txData.TransmitterID, rxInfo.ID);
            sfDB  = obj.LinkInfo.sf(txData.TransmitterID, rxInfo.ID);

            % Identify the UE end of the link (uplink: transmitter,
            % downlink: receiver); gNB-gNB packets fall back to the
            % terrestrial model with the receiver treated as the UT.
            isUEtx = ismember(txData.TransmitterID, obj.UENodeIDs);
            isUErx = ismember(rxInfo.ID, obj.UENodeIDs);
            if isUEtx
                uePos = txPos; bsPos = rxPos;
            else
                uePos = rxPos; bsPos = txPos;
            end
            hUT = uePos(3);

            % The aerial overlay only applies when one end is a UE; pure
            % infrastructure links (gNB-gNB interference paths) always use
            % the terrestrial model, whatever the mast height.
            if hUT > obj.Cfg.zBoundary && (isUEtx || isUErx)
                d3D = max(norm(uePos - bsPos), 1);
                pathLoss = tr36777AerialPathloss(obj.Cfg.scenario, isLOS, ...
                    txData.CenterFrequency/1e9, hUT, d3D);
            else
                pathLoss = nrPathLoss(obj.NRPathLossConfig, ...
                    txData.CenterFrequency, isLOS, bsPos', uePos');
            end
            outputData.Power = outputData.Power - pathLoss - sfDB;

            % ---- Fast fading (unchanged from hNRCustomChannelModel) -----
            if ~isempty(obj.ChannelModelMatrix{txData.TransmitterID, rxInfo.ID})
                obj.ChannelModelMatrix{txData.TransmitterID, rxInfo.ID}.InitialTime = outputData.StartTime;
                if obj.PHYAbstractionMethodNum == 0 % Full PHY
                    rxWaveform = [txData.Data; zeros(obj.MaxChannelDelayMatrix(txData.TransmitterID, rxInfo.ID), ...
                        size(txData.Data,2))];
                    [outputData.Data,outputData.Metadata.Channel.PathGains, outputData.Metadata.Channel.SampleTimes] = ...
                        obj.ChannelModelMatrix{txData.TransmitterID, rxInfo.ID}(rxWaveform);
                    outputData.Data = outputData.Data.*db2mag(-pathLoss-sfDB);
                    outputData.Duration = outputData.Duration + (1/outputData.SampleRate)*obj.MaxChannelDelayMatrix(txData.TransmitterID, rxInfo.ID);
                else % Abstract PHY
                    obj.ChannelModelMatrix{txData.TransmitterID, rxInfo.ID}.NumTimeSamples =  ...
                    txData.Metadata.NumSamples + obj.MaxChannelDelayMatrix(txData.TransmitterID, rxInfo.ID);
                    [outputData.Metadata.Channel.PathGains, outputData.Metadata.Channel.SampleTimes] = ...
                        obj.ChannelModelMatrix{txData.TransmitterID, rxInfo.ID}();
                end
                outputData.Metadata.Channel.PathFilters = ...
                    obj.PathFilter{txData.TransmitterID, rxInfo.ID};
            else
                % No channel model between the Tx and Rx node
                outputData.Metadata.Channel.PathGains = permute(ones(outputData.NumTransmitAntennas,rxInfo.NumReceiveAntennas),[3 4 1 2]) / sqrt(rxInfo.NumReceiveAntennas);
                outputData.Metadata.Channel.PathDelays = 0;
                outputData.Metadata.Channel.PathFilters = 1;
                outputData.Metadata.Channel.SampleTimes = 0;
                if obj.PHYAbstractionMethodNum == 0 % Full PHY
                    numTxAnts = outputData.NumTransmitAntennas;
                    numRxAnts = rxInfo.NumReceiveAntennas;
                    H = fft(eye(max([numTxAnts numRxAnts])));
                    H = H(1:numTxAnts,1:numRxAnts);
                    H = H / norm(H);
                    outputData.Data = txData.Data * H;
                end
            end
        end
    end
end
