classdef handoverManager < handle
%handoverManager Per-UE handover decisions and operator-observable logging.
%
%   One instance per UE. Listens for SRS reception events on every gNB and
%   keeps a per-cell uplink SINR history. On a periodic scan it runs either
%   the TR 36.777 L1/L3-filtered A3 chain (default) or one of the legacy
%   policies in the pool, and appends one feature row plus a per-gNB SINR
%   snapshot.
%
%   Handovers are logical: the serving cell ID is reassigned and the event
%   logged, as the stock nrScheduler cannot drop a UE mid-simulation.

    properties
        gNBs
        UE
        ueRNTI = []   % this UE's RNTI as seen in SRS events, derived once
        networkSimulator
        numCells

        scanPeriod = 0.01
        % gNBs start receiving SRS around 0.0715 s; by 0.0795 s four updates
        % are available to average.
        scanStartTime = 0.0795
        hysteresis = 1             % dB, legacy instant-A3 margin
        sinrThreshold = 20         % dB, A5 event

        % TR 36.777 Table A.2.1-1 baselines, but measured on uplink SRS SINR
        % rather than DL RSRP; see the deviations log.
        useTr36777Mobility = true  % false = legacy instant A3 (1 dB, no TTT)
        a3Offset = 2               % dB
        ttt = 0.160                % s, TimeToTrigger
        l1WindowSec = 0.200        % s, L1 linear filtering window
        l3K = 1                    % L3RRMCoefficient k; a = (1/2)^(k/4)
        hoPrepDelay = 0.050        % s
        hoExecDelay = 0.040        % s
        measErrStd = 1.22          % dB; decision chain only, never the
                                   % logged features
        mtsPingPong = 1            % s, minimum time of stay
        measSeed = 0               % set by the scenario script

        l3SINR = []                % L3-filtered SINR per gNB (dB)
        tttStart = []              % A3 entering-condition start time per gNB
        pendingHO = []             % struct('target',id,'executeAt',t) or []
        measStream = []

        ulSINR                     % [numCells x time]
        gNBCount                   % measurements received per gNB
        ulSINRAverage              % [numCells x 1], last 4 samples per cell
        ullastSINR
        latestSINR = []            % [numCells x 1], time-aligned
        connectedulSINR = []

        ueLabel = ""               % ground truth, "aerial" or "terrestrial"
        featureLog = []
        featureNames = {}
        visThreshold = 0           % min SINR (dB) for a gNB to count visible
        sinrLog = []               % [time, SINR_gNB1..N], NaN for never-heard
                                   % cells; diagnostic only

        handoverPolicy = {}

        dqnAgent_data
        handover_num = 0
        step = 1
        handoverFrom  = []
        handoverTo    = []
        handoverTimes = []
        handoverLog = []           % rows of [fromGNBID, toGNBID, time_s]

        SINR_Threshold = 23        % dB, A2 event
        Hyst = 2                   % dB, A2 event
        ell = 0.6                  % exploration factor in the UCB reward
        tau = 0.08                 % s, allowable delay before A2 handover
        taustep = 3                % column index for tau in the SINR matrix
        connectionStartIdx = 1
        UCBdata
        TransmissionRate_Threshold = 93e6  % bps
        TransmissionRate_Hyst = 1e6        % bps

        ddpg_data
        TTT = 10
        timer = 0
        prev_trigger_step = 0

        mode = 'eval'              % 'eval' or 'train'

        lastTxBytes = []
        lastThroughput = 0         % Mbps
        allthroughput = []
        allthroughput_time = []
        stepsSinceLastHO = 0
        lastTxTime = 0

        ulApp
        dlApp

        verbose = false            % true prints each scan's feature row

        powerTap = []              % phase5b_PowerTap handle; [] leaves the
                                   % three power columns NaN throughout
        numRB = NaN                % measurement bandwidth in resource blocks
        latestRSRP = []            % [numCells x 1], dBm, per SRS event
        latestRSSI = []            % [numCells x 1], dBm
        latestRSRQ = []            % [numCells x 1], dB
        rsrpLog = []               % [time, RSRP_gNB1..N] per scan
        rssiLog = []
        rsrqLog = []
    end

    methods
        function obj = handoverManager(UE,gNBs, networkSimulator, ulApp, dlApp, varargin) 
            obj.gNBs = gNBs;
            obj.UE = UE;
            obj.networkSimulator = networkSimulator;
            obj.numCells = length(gNBs);

            obj.ulApp = ulApp;
            obj.dlApp = dlApp;
            % Comes from the scenario, never inferred from features.
            if nargin > 6
                obj.ueLabel = string(varargin{2});
            end
            % Supplied by the scenario, which knows the registration order.
            % Pinning it from the first observed event collides when two
            % managers share a gNB event stream.
            if nargin > 7
                obj.ueRNTI = varargin{3};
            end
            obj.featureNames = {'time','ueID','label_is_aerial','servingGNB', ...
                'servingSINR','numVisible','maxNeighbourSINR','meanNeighbourSINR', ...
                'sinrSpread','handoverCount','timeSinceLastHO', ...
                'servingRSRP','servingRSSI','servingRSRQ'};

            obj.ulSINR = [];
            obj.ulSINRAverage = [];
            obj.gNBCount = zeros(obj.numCells, 1);
            obj.latestSINR = nan(obj.numCells, 1);   % NaN = never heard yet
            obj.l3SINR   = nan(obj.numCells, 1);
            obj.tttStart = nan(obj.numCells, 1);
            obj.latestRSRP = nan(obj.numCells, 1);
            obj.latestRSSI = nan(obj.numCells, 1);
            obj.latestRSRQ = nan(obj.numCells, 1);

            obj.dqnAgent_data = struct( ...
                'state', [], ...
                'reward', [], ...
                'action', [], ...
                'next_state', [], ...
                'total_reward', 0, ...
                'done', false);

            % R_hat estimated reward, T selections per gNB, H handovers per UE
            obj.UCBdata = struct( ...
                'R_hat', zeros(length(UE), obj.numCells), ...
                'T', zeros(length(UE), obj.numCells), ...
                'H', zeros(length(UE), 1));

            obj.ddpg_data = struct( ...
                'state', [], ...
                'reward', [], ...
                'action', [], ...
                'next_state', [], ...
                'total_reward', 0, ...
                'done', false);

            if nargin > 3
                if strcmp(varargin{1}, 'train') || strcmp(varargin{1}, 'eval')
                    obj.mode = varargin{1};
                else
                    error('Invalid mode specified. Mode should be either "train" or "eval".');
                end
            end

            obj.addHandoverModel(@obj.a3Condition); 
            obj.addHandoverModel(@obj.DQNPolicy); 
            obj.addHandoverModel(@obj.UCBPolicy);
            obj.addHandoverModel(@obj.DDPGPolicy);
            
            addlistener(gNBs, 'PacketReceptionEnded', @(src, eventData) obj.handlePacketReception(src, eventData));
            scheduleAction(networkSimulator, @obj.checkHandoverPolicy, [], obj.scanStartTime, obj.scanPeriod);
        end

        function addHandoverModel(obj, modelHandle)
            obj.handoverPolicy{end + 1} = modelHandle;
        end

        function handlePacketReception(obj, src, event)
            if strcmp(event.EventName, "PacketReceptionEnded") && ...
               strcmp(event.Data.SignalType, "SRS") && ...
               event.Data.CurrentTime * 1e3 > 70

                % Keeps two managers on one gNB event stream separate.
                if isempty(obj.ueRNTI) || event.Data.RNTI ~= obj.ueRNTI
                    return;
                end

                index = src.ID;                       % receiving gNB
                obj.gNBCount(index) = obj.gNBCount(index) + 1;
                obj.ulSINR(index, obj.gNBCount(index)) = event.Data.ChannelMeasurements.SINR;
                obj.latestSINR(index, 1) = event.Data.ChannelMeasurements.SINR;

                % The tap holds this packet's absolute level; without it the
                % three columns stay NaN and nothing else changes.
                if ~isempty(obj.powerTap)
                    pRx = obj.powerTap.read(index, obj.UE.ID, ...
                        event.Data.CurrentTime);
                    [rp, rs, rq] = phase5b_PowerTap.derive(pRx, ...
                        event.Data.ChannelMeasurements.SINR, obj.numRB);
                    obj.latestRSRP(index, 1) = rp;
                    obj.latestRSSI(index, 1) = rs;
                    obj.latestRSRQ(index, 1) = rq;
                end
            end
        end

        function avgSINR = computeAverageSINR(obj, win)
        %computeAverageSINR Average each gNB's own most recent `win` samples.
            % Rows fill independently per gNB, so a global column window would
            % mix time indices and zero-pad lagging cells.
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

                if isempty(obj.lastTxBytes)
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

      function checkHandoverPolicy(obj, ~, ~)
            % Wait for 4 of the serving cell's own measurements before
            % deciding; other cells contribute whatever they have.
            currentIdx = find([obj.gNBs.ID] == obj.UE.GNBNodeID, 1);
            if isempty(currentIdx) || obj.gNBCount(currentIdx) < 4
                return;
            end

            obj.ulSINRAverage = obj.computeAverageSINR(4);
            obj.ullastSINR    = obj.latestSINR(:);

            c = obj.gNBCount(currentIdx);
            obj.connectedulSINR = [obj.connectedulSINR, obj.ulSINR(currentIdx, c-3:c)];
            sinrVec = obj.ulSINRAverage(:);
            servingSINR = sinrVec(currentIdx);
            neighbourMask = true(numel(sinrVec),1);
            neighbourMask(currentIdx) = false;
            neighbourSINR = sinrVec(neighbourMask);

            numVisible = sum(sinrVec > obj.visThreshold);   % NaN cells excluded
            if isempty(neighbourSINR) || all(isnan(neighbourSINR))
                maxNeigh = NaN; meanNeigh = NaN;
            else
                maxNeigh  = max(neighbourSINR, [], 'omitnan');
                meanNeigh = mean(neighbourSINR, 'omitnan');
            end
            sinrSpread = max(sinrVec, [], 'omitnan') - min(sinrVec, [], 'omitnan');

            if isempty(obj.handoverTimes)
                timeSinceHO = obj.networkSimulator.CurrentTime;  % since sim start
            else
                timeSinceHO = obj.networkSimulator.CurrentTime - obj.handoverTimes(end);
            end

            servRSRP = obj.latestRSRP(currentIdx);
            servRSSI = obj.latestRSSI(currentIdx);
            servRSRQ = obj.latestRSRQ(currentIdx);

            labelIsAerial = double(obj.ueLabel == "aerial");
            row = [obj.networkSimulator.CurrentTime, obj.UE.ID, labelIsAerial, ...
                   obj.UE.GNBNodeID, servingSINR, numVisible, maxNeigh, meanNeigh, ...
                   sinrSpread, obj.handover_num, timeSinceHO, ...
                   servRSRP, servRSSI, servRSRQ];
            obj.featureLog(end+1, :) = row;
            obj.sinrLog(end+1, :) = [obj.networkSimulator.CurrentTime, sinrVec(:).'];
            obj.rsrpLog(end+1, :) = [obj.networkSimulator.CurrentTime, obj.latestRSRP(:).'];
            obj.rssiLog(end+1, :) = [obj.networkSimulator.CurrentTime, obj.latestRSSI(:).'];
            obj.rsrqLog(end+1, :) = [obj.networkSimulator.CurrentTime, obj.latestRSRQ(:).'];

            if obj.verbose
                fprintf('t=%.3f UE%d [%-11s] serve=gNB%d SINR=%5.1f vis=%d maxN=%5.1f meanN=%5.1f spread=%4.1f HO=%d\n', ...
                    row(1), row(2), obj.ueLabel, row(4), row(5), row(6), row(7), row(8), row(9), row(10));
            end
            
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

        function tr36777Mobility(obj)
        %tr36777Mobility L1/L3-filtered A3 with time-to-trigger and handover
        % preparation/execution delays, per TR 36.777 Table A.2.1-1 and the
        % TS 36.331 model.
        %     L1: linear average of each gNB's own SRS samples over the
        %         trailing l1WindowSec.
        %     Measurement error: additive Gaussian from a seeded stream,
        %         applied here only; features and sinrLog keep raw averages.
        %     L3: F = (1-a)*F_prev + a*M with a = (1/2)^(l3K/4).
        %     A3: neighbour > serving + a3Offset must hold continuously for
        %         ttt seconds, per-neighbour timers.
        %     Execution: hoPrepDelay + hoExecDelay after the report, with no
        %         new evaluation while a handover is in flight.
            tNow = obj.networkSimulator.CurrentTime;

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

            w = max(1, round(obj.l1WindowSec / obj.scanPeriod));
            l1 = obj.computeAverageSINR(w);

            if obj.measErrStd > 0
                if isempty(obj.measStream)
                    obj.measStream = RandStream('Threefry', 'Seed', ...
                        max(obj.measSeed, 1));
                end
                l1 = l1 + obj.measErrStd * randn(obj.measStream, obj.numCells, 1);
            end

            a = (1/2)^(obj.l3K/4);
            fresh = isnan(obj.l3SINR) & ~isnan(l1);
            obj.l3SINR(fresh) = l1(fresh);
            upd = ~isnan(obj.l3SINR) & ~isnan(l1);
            obj.l3SINR(upd) = (1 - a) * obj.l3SINR(upd) + a * l1(upd);

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

        function targetGNB = DQNPolicy(obj, currentSINR, UE, gNBs)
            if strcmp(obj.mode, 'train')
                currentIdx = find([gNBs.ID] == UE.GNBNodeID, 1);
        
                % State: normalised SINR, one-hot serving cell, delta to best,
                % normalised throughput, time since last HO, handover count.
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
        
                action = py.DDQN.get_action(state);
                actionmat = int32(action) + 1;
                targetGNB = gNBs(actionmat);
        
                isHandover = (targetGNB.ID ~= UE.GNBNodeID);
                if ~isHandover
                    targetGNB = [];
                    obj.stepsSinceLastHO = obj.stepsSinceLastHO + 1;
                else
                    obj.stepsSinceLastHO = 0;
                end
        
                delta_sinr_dB = currentSINR(actionmat) - currentSINR(currentIdx);
                reward = 6 * normSINR(currentIdx) + 2 * tp_norm;
                if isHandover
                    reward = reward - 4;
                    if delta_sinr_dB < 3
                        reward = reward - 3;  % penalty for unnecessary handover
                    end
                else
                    if currentSINR(currentIdx) < 25 && obj.stepsSinceLastHO > 2
                        reward = reward - 4;  % penalty for sticking to poor connection
                    end
                end
                reward = reward - 0.05 * obj.handover_num;
        
                obj.dqnAgent_data.state(:, obj.step) = state;
                obj.dqnAgent_data.action(obj.step) = action;
                obj.dqnAgent_data.reward(obj.step) = reward;
                obj.dqnAgent_data.total_reward = obj.dqnAgent_data.total_reward + reward;
        
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
        
                fprintf('Step %d: Action = %d, Reward = %.3f\n', ...
                    obj.step, action, reward);
        
                obj.step = obj.step + 1;
                global last_handover_num;
                last_handover_num = obj.handover_num;
        
                if obj.step >= 160 || obj.networkSimulator.CurrentTime >= 2
                    obj.dqnAgent_data.done = true;
                else
                    obj.dqnAgent_data.done = false;
                end
        
            elseif strcmp(obj.mode, 'eval')
                currentIdx = find([gNBs.ID] == UE.GNBNodeID, 1);
        
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
        
                % Greedy policy from the pretrained model.
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
        
                action = py.DDQN.get_action(obsInfo);
                actionmat = int32(action) + 1;
                targetGNB = gNBs(actionmat);
        
                isHandover = (targetGNB.ID ~= UE.GNBNodeID);
                if ~isHandover
                    targetGNB = [];
                    obj.stepsSinceLastHO = obj.stepsSinceLastHO + 1;
                else
                    obj.stepsSinceLastHO = 0;
                end
            end
        end






        function targetGNB = UCBPolicy(obj, currentSINR, UE, gNBs)
            targetGNB = [];
            currentIdx = find([gNBs.ID] == UE.GNBNodeID, 1);
        
            if obj.networkSimulator.CurrentTime > obj.tau
                % SINR must have stayed below threshold for tau.
                if all(obj.ulSINR(currentIdx, end - obj.taustep + 1 : end) < obj.SINR_Threshold)
        
                    transmissionRate = obj.calculateTransmissionRate(currentSINR, gNBs);
        
                    acceptable_base_stations = find((transmissionRate(:, 1) >= ...
                        obj.TransmissionRate_Threshold + obj.TransmissionRate_Hyst) & ...
                        ((1:length(gNBs))' ~= currentIdx));
        
                    if ~isempty(acceptable_base_stations)
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
        
                        [~, index] = max(ucb_scores);
                        new_base_station = acceptable_base_stations(index);
        
                        % Cumulative throughput of the current connection.
                        if obj.connectionStartIdx <= length(obj.lastThroughput)
                            currentThroughput = sum(obj.lastThroughput(obj.connectionStartIdx:end));
                        else
                            currentThroughput = 0;
                        end
        
                        if isempty(obj.lastThroughput)
                            obj.connectionStartIdx = 1;
                        else
                            obj.connectionStartIdx = size(obj.lastThroughput, 2) + 1;
                        end
        
                        obj.UCBdata.H(1) = obj.UCBdata.H(1) + 1;
                        obj.UCBdata.T(1, new_base_station) = obj.UCBdata.T(1, new_base_station) + 1;
                        obj.UCBdata.R_hat(1, new_base_station) = ...
                            (obj.UCBdata.R_hat(1, new_base_station) * ...
                            (obj.UCBdata.T(1, new_base_station) - 1) + currentThroughput) / ...
                            obj.UCBdata.T(1, new_base_station);
        
                        targetGNB = gNBs(new_base_station);
                        obj.handover_num = obj.handover_num + 1;
                    end
                end
            end
        
            obj.step = obj.step + 1;
        end
        
        function rate = calculateTransmissionRate(~, currentSINR, gNBs)
        %calculateTransmissionRate Shannon capacity per gNB from its SINR.
            rate = zeros(size(currentSINR));
            for i = 1:length(gNBs)
                bandwidth = gNBs(i).ChannelBandwidth;
                rate(i) = bandwidth * log2(1 + currentSINR(i));
            end
        end


        function targetGNB = DDPGPolicy(obj, currentSINR, UE, gNBs)
            if strcmp(obj.mode, 'train')
                currentIdx = find([gNBs.ID] == UE.GNBNodeID, 1);
                if isempty(currentIdx)
                    targetGNB = [];
                    return;
                end
        
                sinrMax = 30; sinrMin = 0;
                normSINR = (currentSINR - sinrMin) / (sinrMax - sinrMin);
                normSINR = min(max(normSINR, 0), 1);
        
                ulThroughput = obj.lastThroughput * 1000;  % Mbps -> kbps
                throughput_norm = min(max(ulThroughput / 10000, 0), 1);
        
                state = normSINR;
        
                HOM = py.DDPG.get_action(state);
        
                bs_target = 0;
                best_sinr = currentSINR(currentIdx) + HOM;
                for i = 1:length(currentSINR)
                    if i ~= currentIdx && currentSINR(i) > best_sinr
                        best_sinr = currentSINR(i);
                        bs_target = i;
                    end
                end
        
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
        
                w1 = 0.1; w2 = 0.1;
                reward = throughput_norm;
                if isHandover
                    reward = reward - w1;
                    if obj.step - obj.prev_trigger_step < 5
                        reward = reward - w2;  % penalize ping-pong handover
                    end
                    obj.prev_trigger_step = obj.step;
                end
        
                obj.ddpg_data.state(:, obj.step) = state;
                obj.ddpg_data.action(obj.step) = bs_target;
                obj.ddpg_data.reward(obj.step) = reward;
                obj.ddpg_data.total_reward = obj.ddpg_data.total_reward + reward;
        
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
        
                HOM = py.DDPG.get_action(obsInfo, false);
        
                bs_target = 0;
                best_sinr = currentSINR(currentIdx) + HOM;
                for i = 1:length(currentSINR)
                    if i ~= currentIdx && currentSINR(i) > best_sinr
                        best_sinr = currentSINR(i);
                        bs_target = i;
                    end
                end
        
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

        function executeHandover(obj, targetGNB)
        %executeHandover Reassign the serving cell and log the event.
        %   Logical only, because the stock nrScheduler cannot remove a UE
        %   mid-simulation without editing sealed source.
            currentGNBID = obj.UE.GNBNodeID;

            % Writable on the patched nrUE, and every policy method reads it.
            obj.UE.GNBNodeID = targetGNB.ID;

            obj.handover_num = obj.handover_num + 1;
            t = obj.networkSimulator.CurrentTime;
            obj.handoverTimes(end+1) = t;
            obj.handoverLog(end+1, :) = [currentGNBID, targetGNB.ID, t];

            disp("Logical handover: UE" + obj.UE.ID + " from gNB" + ...
                currentGNBID + " to gNB" + targetGNB.ID + " at t=" + t + "s");
        end

        function resetTraffic(obj, targetGNB)
            addTrafficSource(targetGNB, obj.dlApp, 'DestinationNode', obj.UE); 
            addTrafficSource(obj.UE, obj.ulApp); 
        end

        function s = getHandoverStats(obj)
        %getHandoverStats Derive handover statistics from the event log.
            t = obj.handoverTimes(:);
            n = numel(t);
            dur = max(obj.networkSimulator.CurrentTime - obj.scanStartTime, eps);

            s.count   = obj.handover_num;     % equals n under the logical model
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

            % Table A.2.1-1: a handover back to the previous cell inside the
            % minimum time of stay.
            pp = 0;
            for k = 2:n
                if obj.handoverLog(k,2) == obj.handoverLog(k-1,1) ...  % A->B->A
                        && (t(k) - t(k-1)) < obj.mtsPingPong           % within MTS
                    pp = pp + 1;
                end
            end
            s.pingPongCount = pp;
        end
    end
end
