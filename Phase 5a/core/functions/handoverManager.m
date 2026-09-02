classdef handoverManager < handle
    % drives handover decisions for one UE from per-gNB uplink SRS SINR, and logs
    % the operator-observable feature row produced at every scan.

    properties
        % network entities
        gNBs
        UE
        ueRNTI = []   % this UE's SRS RNTI
        networkSimulator
        numCells

        % configuration
        scanPeriod = 0.01          % scan interval, seconds
        scanStartTime = 0.0795     % first scan, seconds
        hysteresis = 1             % legacy A3 margin
        sinrThreshold = 20         % A5 threshold, dB

        % mobility chain, TR 36.777 Table A.2.1-1 baseline values.
        useTr36777Mobility = true  % false uses A3
        a3Offset = 2               % dB
        ttt = 0.160                % seconds
        l1WindowSec = 0.200        % seconds
        l3K = 1                    % filter coefficient
        hoPrepDelay = 0.050        % seconds
        hoExecDelay = 0.040        % seconds
        measErrStd = 1.22          % dB, decision chain only
        mtsPingPong = 1            % minimum time of stay
        measSeed = 0               % measurement-error seed

        % mobility-chain state
        l3SINR = []                % filtered SINR
        tttStart = []              % per-gNB timers
        pendingHO = []             % handover in flight
        measStream = []            % error stream

        % SINR measurements
        ulSINR                    % per-cell SINR history
        gNBCount                 % samples per gNB
        ulSINRAverage            % averaged SINR
        ullastSINR
        latestSINR = []          % most recent SINR
        connectedulSINR = []     % serving-cell SINR
        % feature logging
        ueLabel = ""             % ground-truth label
        featureLog = []          % feature rows
        featureNames = {}        % column names
        visThreshold = 0         % visibility threshold
        sinrLog = []             % per-scan snapshot

        % handover strategies
        handoverPolicy = {}       % registered models

        % agent logging
        dqnAgent_data            % DQN data
        handover_num = 0         % handovers performed
        step = 1                 % decision step
        handoverFrom  = []       % source gNB
        handoverTo    = []       % target gNB
        handoverTimes = []       % handover times
        handoverLog = []         % from, to, time

        % SMART-S parameters
        SINR_Threshold = 23      % A2 threshold, dB
        Hyst = 2                 % A2 hysteresis, dB
        ell = 0.6                % exploration factor
        tau = 0.08               % allowable delay
        taustep = 3              % tau column
        connectionStartIdx = 1   % connection start
        UCBdata                  % SMART-S data
        TransmissionRate_Threshold = 93e6  % bps
        TransmissionRate_Hyst = 1e6        % bps

        % DDPG data
        ddpg_data
        TTT = 10                 % time to trigger
        timer = 0               % countdown timer
        prev_trigger_step = 0   % last trigger step

        % 'eval' or 'train'
        mode = 'eval'

        % throughput tracking
        lastTxBytes = []        % previous bytes
        lastThroughput = 0      % last throughput
        allthroughput = []      % throughput history
        allthroughput_time = [] % throughput times
        stepsSinceLastHO = 0    % steps since handover
        lastTxTime = 0          % last measurement time

        ulApp                   % uplink application
        dlApp                   % downlink application

        verbose = false          % print each scan
    end

    methods
        %% sets up the manager and registers its listeners.
        function obj = handoverManager(UE,gNBs, networkSimulator, ulApp, dlApp, varargin) 
            obj.gNBs = gNBs;
            obj.UE = UE;
            obj.networkSimulator = networkSimulator;
            obj.numCells = length(gNBs);

            obj.ulApp = ulApp;
            obj.dlApp = dlApp;
            % label comes from the scenario, never from features
            if nargin > 6
                obj.ueLabel = string(varargin{2});
            end
            % expected SRS RNTI for this UE, from the scenario
            if nargin > 7
                obj.ueRNTI = varargin{3};
            end
            obj.featureNames = {'time','ueID','label_is_aerial','servingGNB', ...
                'servingSINR','numVisible','maxNeighbourSINR','meanNeighbourSINR', ...
                'sinrSpread','handoverCount','timeSinceLastHO'};

            obj.ulSINR = [];
            obj.ulSINRAverage = [];
            obj.gNBCount = zeros(obj.numCells, 1);
            obj.latestSINR = nan(obj.numCells, 1);   % never heard
            obj.l3SINR   = nan(obj.numCells, 1);     % chain state
            obj.tttStart = nan(obj.numCells, 1);

            % DQN logging
            obj.dqnAgent_data = struct( ...
                'state', [], ...
                'reward', [], ...
                'action', [], ...
                'next_state', [], ...
                'total_reward', 0, ...
                'done', false);

            % UCB logging
            obj.UCBdata = struct( ...
                'R_hat', zeros(length(UE), obj.numCells), ...
                'T', zeros(length(UE), obj.numCells), ...
                'H', zeros(length(UE), 1));

            % DDPG logging
            obj.ddpg_data = struct( ...
                'state', [], ...
                'reward', [], ...
                'action', [], ...
                'next_state', [], ...
                'total_reward', 0, ...
                'done', false);

            % operational mode
            if nargin > 3
                if strcmp(varargin{1}, 'train') || strcmp(varargin{1}, 'eval')
                    obj.mode = varargin{1};
                else
                    error('Invalid mode specified. Mode should be either "train" or "eval".');
                end
            end

            % register the default models
            obj.addHandoverModel(@obj.a3Condition); 
            obj.addHandoverModel(@obj.DQNPolicy); 
            obj.addHandoverModel(@obj.UCBPolicy);
            obj.addHandoverModel(@obj.DDPGPolicy);
            
            % listeners and periodic scan
            addlistener(gNBs, 'PacketReceptionEnded', @(src, eventData) obj.handlePacketReception(src, eventData));
            scheduleAction(networkSimulator, @obj.checkHandoverPolicy, [], obj.scanStartTime, obj.scanPeriod);
        end

        %% adds a handover model to the policy pool.
        function addHandoverModel(obj, modelHandle)
            obj.handoverPolicy{end + 1} = modelHandle;
        end

        %% ingests SRS receptions for this manager's UE.
        function handlePacketReception(obj, src, event)
            if strcmp(event.EventName, "PacketReceptionEnded") && ...
               strcmp(event.Data.SignalType, "SRS") && ...
               event.Data.CurrentTime * 1e3 > 70

            % only this UE's SRS events
                if isempty(obj.ueRNTI) || event.Data.RNTI ~= obj.ueRNTI
                    return;
                end

                index = src.ID;                       % receiving gNB
                obj.gNBCount(index) = obj.gNBCount(index) + 1;
                obj.ulSINR(index, obj.gNBCount(index)) = event.Data.ChannelMeasurements.SINR;
                obj.latestSINR(index, 1) = event.Data.ChannelMeasurements.SINR;
            end
        end

%% averages each gNB's own most recent samples.
        function avgSINR = computeAverageSINR(obj, win)
            % rows fill independently, so average each row over its own
            % last win samples rather than a global column window.
            avgSINR = nan(obj.numCells, 1);
            for i = 1:obj.numCells
                c = obj.gNBCount(i);
                if c == 0
                    continue;
                end
                lo = max(1, c - win + 1);
                avgSINR(i) = mean(obj.ulSINR(i, lo:c));
            end
        end

        %% reads uplink throughput from the application log.
        function throughputMbps = getULThroughput(obj)
            logPath = 'D:\goproject\src\mp-quic\mp-quic-conext17-1\example\reqres_file_loop\client\throughput.log';
            throughputMbps = 0;
            if ~isfile(logPath)
                return;
            end

            try
                fid = fopen(logPath, 'r');
                fseek(fid, -2048, 'eof');
                data = textscan(fid, '%s', 'Delimiter', '\n');
                fclose(fid);
                lines = data{1};
                lastLine = lines{end};

                tokens = regexp(lastLine, ' ', 'split');
                currentTxBytes = str2double(tokens{14});
                currentTime = obj.networkSimulator.CurrentTime;

                if isempty(obj.lastTxBytes)  % first call
                    obj.lastTxBytes = currentTxBytes;
                    obj.lastTxTime = currentTime;
                    return;
                end

                if obj.lastThroughput > currentTxBytes
                    return;
                end

                if currentTxBytes == obj.lastTxBytes
                    throughputMbps = obj.lastThroughput;
                    return;
                end

                deltaBits = (currentTxBytes - obj.lastTxBytes) * 8;
                deltaTime = currentTime - obj.lastTxTime;  
                throughputMbps = deltaBits / (deltaTime * 1e6);

                fprintf('Step %d | deltaTime = %.4f s | deltaBits = %.0f bits | Throughput = %.3f Mbps\n', ...
                    obj.step, deltaTime, deltaBits, throughputMbps);    

                obj.lastTxBytes = currentTxBytes;
                obj.lastTxTime = currentTime;
                obj.lastThroughput = throughputMbps;
                obj.allthroughput = [obj.allthroughput, throughputMbps];
                obj.allthroughput_time = [obj.allthroughput_time, currentTime];

            catch ME
                throughputMbps = 0;
                warning(ME.identifier, "Log read error: %s", ME.message);
            end  
        end

      %% evaluates the handover policy once per scan.
      function checkHandoverPolicy(obj, ~, ~)
            % wait for four serving-cell measurements
            currentIdx = find([obj.gNBs.ID] == obj.UE.GNBNodeID, 1);
            if isempty(currentIdx) || obj.gNBCount(currentIdx) < 4
                return;   % not enough yet
            end

            % average each cell over its own last four samples
            obj.ulSINRAverage = obj.computeAverageSINR(4);
            obj.ullastSINR    = obj.latestSINR(:);

            % record the serving cell's own average
            c = obj.gNBCount(currentIdx);
            obj.connectedulSINR = [obj.connectedulSINR, obj.ulSINR(currentIdx, c-3:c)];
            % build one operator-observable feature row
            sinrVec = obj.ulSINRAverage(:);          % averaged SINR
            servingSINR = sinrVec(currentIdx);
            neighbourMask = true(numel(sinrVec),1);
            neighbourMask(currentIdx) = false;
            neighbourSINR = sinrVec(neighbourMask);

            numVisible = sum(sinrVec > obj.visThreshold);   % NaN excluded
            if isempty(neighbourSINR) || all(isnan(neighbourSINR))
                maxNeigh = NaN; meanNeigh = NaN;
            else
                maxNeigh  = max(neighbourSINR, [], 'omitnan');
                meanNeigh = mean(neighbourSINR, 'omitnan');
            end
            sinrSpread = max(sinrVec, [], 'omitnan') - min(sinrVec, [], 'omitnan');

            if isempty(obj.handoverTimes)
                timeSinceHO = obj.networkSimulator.CurrentTime;  % since start
            else
                timeSinceHO = obj.networkSimulator.CurrentTime - obj.handoverTimes(end);
            end

            labelIsAerial = double(obj.ueLabel == "aerial");
            row = [obj.networkSimulator.CurrentTime, obj.UE.ID, labelIsAerial, ...
                   obj.UE.GNBNodeID, servingSINR, numVisible, maxNeigh, meanNeigh, ...
                   sinrSpread, obj.handover_num, timeSinceHO];
            obj.featureLog(end+1, :) = row;
            % full snapshot for offline diagnostics
            obj.sinrLog(end+1, :) = [obj.networkSimulator.CurrentTime, sinrVec(:).'];

           % optional per-scan print
            if obj.verbose
                fprintf('t=%.3f UE%d [%-11s] serve=gNB%d SINR=%5.1f vis=%d maxN=%5.1f meanN=%5.1f spread=%4.1f HO=%d\n', ...
                    row(1), row(2), obj.ueLabel, row(4), row(5), row(6), row(7), row(8), row(9), row(10));
            end
            
            % run the mobility chain, or legacy A3
            if obj.useTr36777Mobility
                obj.tr36777Mobility();
            else
                model = obj.handoverPolicy{1};
                targetGNB = model(obj.ulSINRAverage, obj.UE, obj.gNBs);
                if ~isempty(targetGNB)
                    obj.executeHandover(targetGNB);
                end
            end
        end

        %% runs the TR 36.777 mobility chain: L1 and L3 filtering, event A3 with
        function tr36777Mobility(obj)
        % time-to-trigger, then preparation and execution delays.
            tNow = obj.networkSimulator.CurrentTime;

            % execute an in-flight handover when due
            if ~isempty(obj.pendingHO)
                if tNow >= obj.pendingHO.executeAt
                    tgtIdx = find([obj.gNBs.ID] == obj.pendingHO.target, 1);
                    if ~isempty(tgtIdx) && obj.pendingHO.target ~= obj.UE.GNBNodeID
                        obj.executeHandover(obj.gNBs(tgtIdx));
                    end
                    obj.pendingHO = [];
                    obj.tttStart(:) = NaN;
                end
                return;
            end

            % L1 filtering
            w = max(1, round(obj.l1WindowSec / obj.scanPeriod));
            l1 = obj.computeAverageSINR(w);

            % measurement error, decision chain only
            if obj.measErrStd > 0
                if isempty(obj.measStream)
                    obj.measStream = RandStream('Threefry', 'Seed', ...
                        max(obj.measSeed, 1));
                end
                l1 = l1 + obj.measErrStd * randn(obj.measStream, obj.numCells, 1);
            end

            % L3 filtering
            a = (1/2)^(obj.l3K/4);
            fresh = isnan(obj.l3SINR) & ~isnan(l1);
            obj.l3SINR(fresh) = l1(fresh);
            upd = ~isnan(obj.l3SINR) & ~isnan(l1);
            obj.l3SINR(upd) = (1 - a) * obj.l3SINR(upd) + a * l1(upd);

            % event A3 with per-neighbour time-to-trigger
            servIdx = find([obj.gNBs.ID] == obj.UE.GNBNodeID, 1);
            if isempty(servIdx) || isnan(obj.l3SINR(servIdx))
                return;
            end
            for n = 1:obj.numCells
                if n == servIdx || isnan(obj.l3SINR(n))
                    obj.tttStart(n) = NaN;
                    continue;
                end
                if obj.l3SINR(n) > obj.l3SINR(servIdx) + obj.a3Offset
                    if isnan(obj.tttStart(n))
                        obj.tttStart(n) = tNow;
                    end
                else
                    obj.tttStart(n) = NaN;
                end
            end
            held = find(~isnan(obj.tttStart) & ...
                (tNow - obj.tttStart >= obj.ttt));
            if ~isempty(held)
                [~, bi] = max(obj.l3SINR(held));
                obj.pendingHO = struct( ...
                    'target', obj.gNBs(held(bi)).ID, ...
                    'executeAt', tNow + obj.hoPrepDelay + obj.hoExecDelay);
                obj.tttStart(:) = NaN;
            end
        end

        %% legacy instant A3 policy.
        function targetGNB = a3Condition(obj, currentSINR, UE, gNBs)
            currentIdx = find([gNBs.ID] == UE.GNBNodeID, 1);
            S_SINR = currentSINR(currentIdx);
          

            for i = 1:length(gNBs)
                if i == currentIdx, continue; end
                if currentSINR(i) > (S_SINR + obj.hysteresis)
                    targetGNB = gNBs(i);
                    return;
                end
            end
            targetGNB = [];
        end

        %% DQN handover policy.
        function targetGNB = DQNPolicy(obj, currentSINR, UE, gNBs)
            if strcmp(obj.mode, 'train')
                % current gNB index
                currentIdx = find([gNBs.ID] == UE.GNBNodeID, 1);
        
                % build the state vector
                sinrMax = 30; sinrMin = 0;
                normSINR = min(max((currentSINR - sinrMin) / (sinrMax - sinrMin), 0), 1);
                oneHot = zeros(length(gNBs), 1);
                oneHot(currentIdx) = 1;
                [~, bestIdx] = max(normSINR);
                deltaToBest = normSINR(bestIdx) - normSINR(currentIdx);
                tp_norm = min(obj.lastThroughput / 1.0, 1);
                timeSinceLastHO = min(obj.stepsSinceLastHO / 100, 1);
                handoverCount = min(obj.handover_num / 100, 1);
                state = [normSINR; oneHot; deltaToBest; tp_norm; timeSinceLastHO; handoverCount];
        
                % pick an action
                action = py.DDQN.get_action(state);
                actionmat = int32(action) + 1;
                targetGNB = gNBs(actionmat);
        
                % handover decision
                isHandover = (targetGNB.ID ~= UE.GNBNodeID);
                if ~isHandover
                    targetGNB = [];
                    obj.stepsSinceLastHO = obj.stepsSinceLastHO + 1;
                else
                    obj.stepsSinceLastHO = 0;
                end
        
                % reward
                delta_sinr_dB = currentSINR(actionmat) - currentSINR(currentIdx);
                reward = 6 * normSINR(currentIdx) + 2 * tp_norm;
                if isHandover
                    reward = reward - 4;
                    if delta_sinr_dB < 3
                        reward = reward - 3;  % unnecessary handover
                    end
                else
                    if currentSINR(currentIdx) < 25 && obj.stepsSinceLastHO > 2
                        reward = reward - 4;  % poor connection
                    end
                end
                reward = reward - 0.05 * obj.handover_num;
        
                % store the experience
                obj.dqnAgent_data.state(:, obj.step) = state;
                obj.dqnAgent_data.action(obj.step) = action;
                obj.dqnAgent_data.reward(obj.step) = reward;
                obj.dqnAgent_data.total_reward = obj.dqnAgent_data.total_reward + reward;
        
                % learn
                if obj.step >= 2
                    learn_success = py.DDQN.learn( ...
                        obj.dqnAgent_data.state(:, obj.step - 1), ...
                        int32(obj.dqnAgent_data.action(obj.step - 1)), ...
                        double(obj.dqnAgent_data.reward(obj.step - 1)), ...
                        obj.dqnAgent_data.state(:, obj.step), ...
                        logical(obj.dqnAgent_data.done));
                    if ~learn_success
                        error('DQN learning failed');
                    end
                end
        
                % step info
                fprintf('Step %d: Action = %d, Reward = %.3f\n', ...
                    obj.step, action, reward);
        
                obj.step = obj.step + 1;
                global last_handover_num;
                last_handover_num = obj.handover_num;
        
                % termination
                if obj.step >= 160 || obj.networkSimulator.CurrentTime >= 2
                    obj.dqnAgent_data.done = true;
                else
                    obj.dqnAgent_data.done = false;
                end
        
            elseif strcmp(obj.mode, 'eval')
                % evaluation mode
                currentIdx = find([gNBs.ID] == UE.GNBNodeID, 1);
        
                % build the observation
                sinrMax = 30; sinrMin = 0;
                normSINR = min(max((currentSINR - sinrMin) / (sinrMax - sinrMin), 0), 1);
                oneHot = zeros(length(gNBs), 1);
                oneHot(currentIdx) = 1;
                [~, bestIdx] = max(normSINR);
                deltaToBest = normSINR(bestIdx) - normSINR(currentIdx);
                tp_norm = min(obj.lastThroughput / 1.0, 1);
                timeSinceLastHO = min(obj.stepsSinceLastHO / 100, 1);
                handoverCount = min(obj.handover_num / 100, 1);
                obsInfo = [normSINR; oneHot; deltaToBest; tp_norm; timeSinceLastHO; handoverCount];
        
                % load the pretrained model
                state_dim = int32(14); action_dim = int32(5);
                config = py.dict(pyargs( ...
                    'learning_rate', 0.0005, ...
                    'gamma', 0.98, ...
                    'epsilon', 1.0, ...
                    'epsilon_decay', 0.95, ...
                    'epsilon_min', 0.01, ...
                    'batch_size', int32(128), ...
                    'memory_size', int32(50000), ...
                    'target_update_freq', int32(100), ...
                    'use_dueling', true, ...
                    'n_step', int32(2) ...
                ));
                py.DDQN.init_agent(state_dim, action_dim, config);
                py.DDQN.load_model('trained_model_17.pth');
        
                % inference
                action = py.DDQN.get_action(obsInfo);
                actionmat = int32(action) + 1;
                targetGNB = gNBs(actionmat);
        
                % handover decision
                isHandover = (targetGNB.ID ~= UE.GNBNodeID);
                if ~isHandover
                    targetGNB = [];
                    obj.stepsSinceLastHO = obj.stepsSinceLastHO + 1;
                else
                    obj.stepsSinceLastHO = 0;
                end
            end
        end






        %% UCB handover policy.
   
        function targetGNB = UCBPolicy(obj, currentSINR, UE, gNBs)
            % init
            targetGNB = [];
            currentIdx = find([gNBs.ID] == UE.GNBNodeID, 1);
        
            if obj.networkSimulator.CurrentTime > obj.tau
                % has SINR stayed below threshold for tau
                if all(obj.ulSINR(currentIdx, end - obj.taustep + 1 : end) < obj.SINR_Threshold)
        
                    % Shannon capacity estimate
                    transmissionRate = obj.calculateTransmissionRate(currentSINR, gNBs);
        
                    % candidate base stations
                    acceptable_base_stations = find((transmissionRate(:, 1) >= ...
                        obj.TransmissionRate_Threshold + obj.TransmissionRate_Hyst) & ...
                        ((1:length(gNBs))' ~= currentIdx));
        
                    if ~isempty(acceptable_base_stations)
                        % UCB scores
                        ucb_scores = zeros(size(acceptable_base_stations));
                        for i = 1:length(acceptable_base_stations)
                            bs = acceptable_base_stations(i);
                            if obj.UCBdata.T(1, bs) == 0
                                ucb_scores(i) = Inf;
                            else
                                ucb_scores(i) = obj.UCBdata.R_hat(1, bs) + ...
                                    obj.ell * sqrt(2 * log(obj.UCBdata.H(1)) / obj.UCBdata.T(1, bs));
                            end
                        end
        
                        % best score
                        [~, index] = max(ucb_scores);
                        new_base_station = acceptable_base_stations(index);
        
                        % cumulative throughput
                        if obj.connectionStartIdx <= length(obj.lastThroughput)
                            currentThroughput = sum(obj.lastThroughput(obj.connectionStartIdx:end));
                        else
                            currentThroughput = 0;
                        end
        
                        % update start index
                        if isempty(obj.lastThroughput)
                            obj.connectionStartIdx = 1;
                        else
                            obj.connectionStartIdx = size(obj.lastThroughput, 2) + 1;
                        end
        
                        % update statistics
                        obj.UCBdata.H(1) = obj.UCBdata.H(1) + 1;
                        obj.UCBdata.T(1, new_base_station) = obj.UCBdata.T(1, new_base_station) + 1;
                        obj.UCBdata.R_hat(1, new_base_station) = ...
                            (obj.UCBdata.R_hat(1, new_base_station) * ...
                            (obj.UCBdata.T(1, new_base_station) - 1) + currentThroughput) / ...
                            obj.UCBdata.T(1, new_base_station);
        
                        % final decision
                        targetGNB = gNBs(new_base_station);
                        obj.handover_num = obj.handover_num + 1;
                    end
                end
            end
        
            obj.step = obj.step + 1;
        end
        
        % returns the Shannon-capacity rate for each gNB SINR.
        function rate = calculateTransmissionRate(~, currentSINR, gNBs)
            rate = zeros(size(currentSINR));
            for i = 1:length(gNBs)
                bandwidth = gNBs(i).ChannelBandwidth;
                rate(i) = bandwidth * log2(1 + currentSINR(i));
            end
        end


        %% DDPG handover policy.
        function targetGNB = DDPGPolicy(obj, currentSINR, UE, gNBs)
            if strcmp(obj.mode, 'train')
                % current gNB index
                currentIdx = find([gNBs.ID] == UE.GNBNodeID, 1);
                if isempty(currentIdx)
                    targetGNB = [];
                    return;
                end
        
                % normalised state vector
                sinrMax = 30; sinrMin = 0;
                normSINR = (currentSINR - sinrMin) / (sinrMax - sinrMin);
                normSINR = min(max(normSINR, 0), 1);
        
                ulThroughput = obj.lastThroughput * 1000;  % kbps
                throughput_norm = min(max(ulThroughput / 10000, 0), 1);
        
                state = normSINR;
        
                % query the agent
                HOM = py.DDPG.get_action(state);
        
                % evaluate candidates
                bs_target = 0;
                best_sinr = currentSINR(currentIdx) + HOM;
                for i = 1:length(currentSINR)
                    if i ~= currentIdx && currentSINR(i) > best_sinr
                        best_sinr = currentSINR(i);
                        bs_target = i;
                    end
                end
        
                % apply the trigger timer
                if bs_target > 0
                    if obj.timer < obj.TTT - 1
                        obj.timer = obj.timer + 1;
                        bs_target = currentIdx;
                    else
                        obj.timer = 0;
                    end
                else
                    if obj.timer < obj.TTT
                        obj.timer = obj.timer + 1;
                    else
                        obj.timer = 0;
                    end
                end 
        
                isHandover = (currentIdx ~= bs_target) && (bs_target > 0);
                if isHandover
                    targetGNB = gNBs(bs_target);
                else
                    targetGNB = [];
                    bs_target = currentIdx;
                end
        
                % reward
                w1 = 0.1; w2 = 0.1;
                reward = throughput_norm;
                if isHandover
                    reward = reward - w1;
                    if obj.step - obj.prev_trigger_step < 5
                        reward = reward - w2;  % ping-pong penalty
                    end
                    obj.prev_trigger_step = obj.step;
                end
        
                % store the transition
                obj.ddpg_data.state(:, obj.step) = state;
                obj.ddpg_data.action(obj.step) = bs_target;
                obj.ddpg_data.reward(obj.step) = reward;
                obj.ddpg_data.total_reward = obj.ddpg_data.total_reward + reward;
        
                % learn
                if obj.step >= 2
                    learn_success = py.DDPG.learn( ...
                        obj.ddpg_data.state(:, obj.step - 1), ...
                        int32(obj.ddpg_data.action(obj.step - 1)), ...
                        double(obj.ddpg_data.reward(obj.step - 1)), ...
                        obj.ddpg_data.state(:, obj.step), ...
                        logical(obj.ddpg_data.done));
                    if ~learn_success
                        error('DDPG learning failed');
                    end
                end
        
                fprintf('Step %d: Action = %d, Reward = %.3f\n', obj.step, bs_target, reward);
                obj.step = obj.step + 1;
                global last_handover_num;
                last_handover_num = obj.handover_num;
        
            elseif strcmp(obj.mode, 'eval')
                % load the trained model
                state_dim = 5;
                action_dim = 1;
                actor_path = 'trained_ddpg_actor_model3.pth';
                critic_path = 'trained_ddpg_critic_model3.pth';
                py.DDPG.init_agent(int32(state_dim), int32(action_dim));
                py.DDPG.load_model(actor_path, critic_path);
        
                currentIdx = find([gNBs.ID] == UE.GNBNodeID, 1);
                if isempty(currentIdx)
                    targetGNB = [];
                    return;
                end
        
                sinrMax = 30; sinrMin = 0;
                normSINR = (currentSINR - sinrMin) / (sinrMax - sinrMin);
                normSINR = min(max(normSINR, 0), 1);
                obsInfo = normSINR;
        
                % get the action
                HOM = py.DDPG.get_action(obsInfo, false);
        
                bs_target = 0;
                best_sinr = currentSINR(currentIdx) + HOM;
                for i = 1:length(currentSINR)
                    if i ~= currentIdx && currentSINR(i) > best_sinr
                        best_sinr = currentSINR(i);
                        bs_target = i;
                    end
                end
        
                % apply the timer
                if bs_target > 0
                    if obj.timer < obj.TTT - 1
                        obj.timer = obj.timer + 1;
                        bs_target = currentIdx;
                    else
                        obj.prev_trigger_step = obj.step;
                        obj.timer = 0;
                    end
                else
                    if obj.timer < obj.TTT
                        obj.timer = obj.timer + 1;
                    else
                        obj.timer = 0;
                    end
                end
        
                isHandover = (currentIdx ~= bs_target) && (bs_target > 0);
                if isHandover
                    targetGNB = gNBs(bs_target);
                else
                    targetGNB = [];
                end
            end
        end



        %% forces a handover when the serving cell fails.
        function emergencyHandover(obj)
            currentIdx = find([obj.gNBs.ID] == obj.UE.GNBNodeID, 1);

            for i = 1:length(obj.ulSINRAverage)
                if i ~= currentIdx && obj.ulSINRAverage(i) > obj.sinrThreshold
                    targetGNB = obj.gNBs(i);
                    obj.executeHandover(targetGNB);
                    return;
                end
            end
        end

        %% performs the logical handover.
function executeHandover(obj, targetGNB)
            % logical handover only: the stock scheduler cannot move a UE
            % mid-simulation, so only the serving cell and the handover
            % bookkeeping change.
            currentGNBID = obj.UE.GNBNodeID;

            % point the logical serving cell at the target
            obj.UE.GNBNodeID = targetGNB.ID;

            % record the event for feature extraction
            obj.handover_num = obj.handover_num + 1;
            t = obj.networkSimulator.CurrentTime;
            obj.handoverTimes(end+1) = t;
            obj.handoverLog(end+1, :) = [currentGNBID, targetGNB.ID, t];

            disp("Logical handover: UE" + obj.UE.ID + " from gNB" + ...
                currentGNBID + " to gNB" + targetGNB.ID + " at t=" + t + "s");
        end

%% restarts the traffic flows after a handover.
        function resetTraffic(obj, targetGNB)
            addTrafficSource(targetGNB, obj.dlApp, 'DestinationNode', obj.UE); 
            addTrafficSource(obj.UE, obj.ulApp); 
        end

        %% derives the handover statistics from the event log.
        function s = getHandoverStats(obj)
            t = obj.handoverTimes(:);
            n = numel(t);
            dur = max(obj.networkSimulator.CurrentTime - obj.scanStartTime, eps);

            s.count   = obj.handover_num;     % equals n
            s.times   = t;
            s.interHO = diff(t);
            s.rate    = n / dur;

            if ~isempty(obj.handoverLog)
                s.uniqueCells = numel(unique(obj.handoverLog(:,1:2)));
            else
                s.uniqueCells = 0;
            end

            if n >= 2
                s.meanInterHO = mean(s.interHO);
                s.stdInterHO  = std(s.interHO);
                s.minInterHO  = min(s.interHO);
                s.cvInterHO   = s.stdInterHO / s.meanInterHO;
            else
                [s.meanInterHO, s.stdInterHO, s.minInterHO, s.cvInterHO] = deal(NaN);
            end

            % ping-pong: a return to the previous cell inside the
            % minimum time of stay.
            pp = 0;
            for k = 2:n
                if obj.handoverLog(k,2) == obj.handoverLog(k-1,1) ...  % A to B to A
                        && (t(k) - t(k-1)) < obj.mtsPingPong           % within MTS
                    pp = pp + 1;
                end
            end
            s.pingPongCount = pp;
        end
    end
end
