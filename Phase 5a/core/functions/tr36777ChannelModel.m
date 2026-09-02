classdef tr36777ChannelModel
    % applies height-switched pathloss and CDL fast fading to every packet, using
    % the live node positions rather than the setup-time geometry.

    properties (SetAccess=private)
        % "linkToSystemMapping" or "none"
        PHYAbstractionMethod = "linkToSystemMapping"

        % scenario configuration struct
        Cfg

        % per-link LOS states and shadow fading
        LinkInfo

        % UE node ids
        UENodeIDs

        % terrestrial pathloss configuration
        NRPathLossConfig

        % per-link channel models
        ChannelModelMatrix

        % per-link maximum channel delay
        MaxChannelDelayMatrix

        % per-link path filters
        PathFilter
    end

    properties(Access=private)
        PHYAbstractionMethodNum
    end

    methods
        function obj = tr36777ChannelModel(channelModelMatrix, cfg, linkInfo, ueNodeIDs)
            % store the channel matrix and config

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
            % applies pathloss and fast fading to one packet.

            outputData = txData;

            % height-switched pathloss, TR 36.777 Annex B.
            txPos = txData.TransmitterPosition(:).';
            rxPos = rxInfo.Position(:).';

            % find the UE end of the link
            isUEtx = ismember(txData.TransmitterID, obj.UENodeIDs);
            isUErx = ismember(rxInfo.ID, obj.UENodeIDs);
            if isUEtx
                uePos = txPos; bsPos = rxPos;
                ueID  = txData.TransmitterID; gnbID = rxInfo.ID;
            else
                uePos = rxPos; bsPos = txPos;
                ueID  = rxInfo.ID; gnbID = txData.TransmitterID;
            end
            hUT = uePos(3);

            % LOS state and shadow fading at the live positions
            if isUEtx || isUErx
                st    = linkState(obj.LinkInfo, obj.Cfg, gnbID, ueID, ...
                    bsPos, uePos);
                isLOS = st.isLOS;
                sfDB  = st.sfDB;
            else
                isLOS = obj.LinkInfo.los(txData.TransmitterID, rxInfo.ID);
                sfDB  = obj.LinkInfo.sf(txData.TransmitterID, rxInfo.ID);
            end

            % the aerial overlay only applies when one end is a UE
            if hUT > obj.Cfg.zBoundary && (isUEtx || isUErx)
                d3D = max(norm(uePos - bsPos), 1);
                pathLoss = tr36777AerialPathloss(obj.Cfg.scenario, isLOS, ...
                    txData.CenterFrequency/1e9, hUT, d3D);
            else
                pathLoss = nrPathLoss(obj.NRPathLossConfig, ...
                    txData.CenterFrequency, isLOS, bsPos', uePos');
            end
            outputData.Power = outputData.Power - pathLoss - sfDB;

            % fast fading
            if ~isempty(obj.ChannelModelMatrix{txData.TransmitterID, rxInfo.ID})
                obj.ChannelModelMatrix{txData.TransmitterID, rxInfo.ID}.InitialTime = outputData.StartTime;
                if obj.PHYAbstractionMethodNum == 0 % full PHY
                    rxWaveform = [txData.Data; zeros(obj.MaxChannelDelayMatrix(txData.TransmitterID, rxInfo.ID), ...
                        size(txData.Data,2))];
                    [outputData.Data,outputData.Metadata.Channel.PathGains, outputData.Metadata.Channel.SampleTimes] = ...
                        obj.ChannelModelMatrix{txData.TransmitterID, rxInfo.ID}(rxWaveform);
                    outputData.Data = outputData.Data.*db2mag(-pathLoss-sfDB);
                    outputData.Duration = outputData.Duration + (1/outputData.SampleRate)*obj.MaxChannelDelayMatrix(txData.TransmitterID, rxInfo.ID);
                else % abstract PHY
                    obj.ChannelModelMatrix{txData.TransmitterID, rxInfo.ID}.NumTimeSamples =  ...
                    txData.Metadata.NumSamples + obj.MaxChannelDelayMatrix(txData.TransmitterID, rxInfo.ID);
                    [outputData.Metadata.Channel.PathGains, outputData.Metadata.Channel.SampleTimes] = ...
                        obj.ChannelModelMatrix{txData.TransmitterID, rxInfo.ID}();
                end
                outputData.Metadata.Channel.PathFilters = ...
                    obj.PathFilter{txData.TransmitterID, rxInfo.ID};
            else
                % no channel model here
                outputData.Metadata.Channel.PathGains = permute(ones(outputData.NumTransmitAntennas,rxInfo.NumReceiveAntennas),[3 4 1 2]) / sqrt(rxInfo.NumReceiveAntennas);
                outputData.Metadata.Channel.PathDelays = 0;
                outputData.Metadata.Channel.PathFilters = 1;
                outputData.Metadata.Channel.SampleTimes = 0;
                if obj.PHYAbstractionMethodNum == 0 % full PHY
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
