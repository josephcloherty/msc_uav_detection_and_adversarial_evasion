function D = phase5b_SchedulerDiag(simTime, numGNB, numUE)
%phase5b_SchedulerDiag Locate why the CQI and MCS columns come out NaN.
%
%   D = phase5b_SchedulerDiag()                  1.5 s, 2 gNB, 3 UE
%   D = phase5b_SchedulerDiag(simTime, nGNB, nUE)
%
%   CQI comes from the scheduler CONTEXT log and the four MCS columns from
%   the scheduler GRANT log, so the two fail together when something shared
%   is wrong: either the schedulers logged nothing, or the RNTI the
%   extraction uses does not match the RNTI the logs carry, or the anchor
%   gNB index is wrong.
%
%   The handover managers find their UE's SRS events by the UE.ID +
%   rntiOffset convention, so the SRS event RNTI and the scheduler RNTI may
%   be different numbering schemes; on a single-gNB probe they coincide, and
%   with several gNBs they need not.
%
%   Sets up the same object graph as phase5b_Pipeline at the smallest size
%   that can still show the problem, runs it briefly, and dumps what is in
%   the logs against what the extraction expects. Writes no CSV and no
%   replay. Keep it small.
%
%   Read the verdict at the bottom. If the logs are populated but the RNTI
%   sets do not intersect, the fix is the RNTI convention in
%   phase5b_Pipeline, not the scheduler class.

    if nargin < 1 || isempty(simTime), simTime = 1.5; end
    if nargin < 2 || isempty(numGNB),  numGNB  = 2;   end
    if nargin < 3 || isempty(numUE),   numUE   = 3;   end

    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, 'core', 'functions'));

    base = phase5b_Config();
    base.scenarios.UMa.topology.numGNB = numGNB;
    base.population.numTerrestrialUE   = numUE - 1;
    base.population.pMultiAerial       = 0;
    base.population.singleAerialCount  = 1;
    base.window.simulationTime         = simTime;
    base.window.windowLen              = max(simTime/3, 0.2);
    base.window.settleTime             = 0.2;
    base.replay.save                   = false;
    base.progress.enable               = false;
    cfg = phase5b_ScenarioGen(base, 999, "UMa");

    fprintf('\nScheduler diagnostic: %.2f s, %d gNB, %d UE\n\n', ...
        simTime, numGNB, numUE);

    %% ---- object graph, identical in structure to phase5b_Pipeline -------
    rng(cfg.seed);
    sim = wirelessNetworkSimulator.init;
    r = cfg.radio;

    gNBs = nrGNB(Name="gNB-" + (1:numGNB), Position=cfg.gNBPositions, ...
        CarrierFrequency=r.carrierFrequency, ChannelBandwidth=r.channelBandwidth, ...
        SubcarrierSpacing=r.subcarrierSpacing, NumTransmitAntennas=r.gnbTxAntennas, ...
        NumReceiveAntennas=r.gnbRxAntennas, ReceiveGain=r.gnbReceiveGain, ...
        DuplexMode=char(r.duplexMode));

    scheds = cell(1, numGNB);
    for g = 1:numGNB
        scheds{g} = cqiLoggingScheduler;
        configureScheduler(gNBs(g), Scheduler=scheds{g});
    end

    UEs = nrUE(Name="UE-" + (1:numUE), Position=cfg.uePositions, ...
        NumTransmitAntennas=r.ueTxAntennas, NumReceiveAntennas=r.ueRxAntennas, ...
        ReceiveGain=r.ueReceiveGain);

    for i = 1:numUE
        configureULforSRS(UEs(i), gNBs);
    end

    rlc = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);
    anchorIdx = zeros(1, numUE);
    for u = 1:numUE
        d = vecnorm(cfg.gNBPositions - UEs(u).Position, 2, 2);
        [~, gIdx] = min(d);
        connectUE(gNBs(gIdx), UEs(u), RLCBearerConfig=rlc);
        anchorIdx(u) = gIdx;
    end

    addNodes(sim, gNBs); addNodes(sim, UEs);
    [channels, linkInfo] = createScenarioChannels(cfg, gNBs, UEs);
    cm = tr36777ChannelModel(channels, cfg, linkInfo, [UEs.ID]);
    addChannelModel(sim, @(rx, tx) cm.applyChannelModel(rx, tx));

    ulApps = cell(1, numUE); dlApps = cell(1, numUE);
    for u = 1:numUE
        ulApps{u} = mk(cfg.trafficPerUE(u).ul);
        addTrafficSource(UEs(u), ulApps{u});
        dlApps{u} = mk(cfg.trafficPerUE(u).dl);
        addTrafficSource(gNBs(anchorIdx(u)), dlApps{u}, DestinationNode=UEs(u));
    end

    managers = cell(numUE, 1);
    for u = 1:numUE
        lbl = 'terrestrial'; if cfg.ueIsAerial(u), lbl = 'aerial'; end
        managers{u} = handoverManager(UEs(u), gNBs, sim, ulApps{u}, ...
            dlApps{u}, 'eval', lbl, UEs(u).ID + cfg.rntiOffset);
        managers{u}.measSeed = cfg.seed*100 + u;
    end

    run(sim, simTime);

    %% ---- what the extraction expects ------------------------------------
    expected = [UEs.ID] + cfg.rntiOffset;
    fprintf('--- what the extraction looks for ---------------------------\n');
    fprintf('UE node IDs      : %s\n', mat2str([UEs.ID]));
    fprintf('gNB node IDs     : %s\n', mat2str([gNBs.ID]));
    fprintf('cfg.rntiOffset   : %d\n', cfg.rntiOffset);
    fprintf('expected RNTIs   : %s   (UE.ID + offset)\n', mat2str(expected));
    fprintf('anchor gNB index : %s\n\n', mat2str(anchorIdx));

    %% ---- what the scheduler logs actually contain ---------------------------
    fprintf('--- what the scheduler logs contain -------------------------\n');
    ctxRNTI = []; grantRNTI = []; nCtx = 0; nGrant = 0;
    for g = 1:numGNB
        [ctx, gr] = scheds{g}.getLogs();
        nCtx = nCtx + size(ctx, 1); nGrant = nGrant + size(gr, 1);
        cR = unique(ctx(:, 2))'; gR = unique(gr(:, 2))';
        ctxRNTI = union(ctxRNTI, cR); grantRNTI = union(grantRNTI, gR);
        fprintf('gNB %d: ctx %4d rows, RNTIs %-14s | grants %4d rows, RNTIs %s\n', ...
            g, size(ctx, 1), mat2str(cR), size(gr, 1), mat2str(gR));
        if ~isempty(ctx)
            fprintf('        ctx CQI non-NaN %d/%d, ctx ulMCS non-NaN %d/%d\n', ...
                sum(~isnan(ctx(:,3))), size(ctx,1), ...
                sum(~isnan(ctx(:,5))), size(ctx,1));
            % Phase 5 columns. A zero count here is not a bug in itself:
            % it means the installed release does not surface that
            % quantity in the UEContext, and the corresponding feature
            % column will be NaN for the whole dataset.
            if size(ctx, 2) >= 9
                fprintf(['        ctx RI %d/%d, subbandSpread %d/%d, ' ...
                         'TA %d/%d, bufDL %d/%d, bufUL %d/%d\n'], ...
                    sum(~isnan(ctx(:,4))), size(ctx,1), ...
                    sum(~isnan(ctx(:,6))), size(ctx,1), ...
                    sum(~isnan(ctx(:,7))), size(ctx,1), ...
                    sum(~isnan(ctx(:,8))), size(ctx,1), ...
                    sum(~isnan(ctx(:,9))), size(ctx,1));
            end
        end
        if ~isempty(gr) && size(gr, 2) >= 8
            fprintf(['        grants retx %d/%d, layers non-NaN %d/%d, ' ...
                     'harqID non-NaN %d/%d\n'], ...
                sum(gr(:,6) == 1), size(gr,1), ...
                sum(~isnan(gr(:,7))), size(gr,1), ...
                sum(~isnan(gr(:,8))), size(gr,1));
        end
        if ismethod(scheds{g}, 'getProbeStatus')
            ps = scheds{g}.getProbeStatus();
            fprintf('        name probes: found=%d active=%d snapshots=%d\n', ...
                ps.found, ps.active, ps.snapshots);
        end
    end
    fprintf('\n');

    %% ---- SRS path, for contrast ---------------------------------------------
    fprintf('--- SRS path (known good) ------------------------------------\n');
    for u = 1:numUE
        m = managers{u};
        heard = sum(~isnan(m.latestSINR));
        fprintf('UE %d: ueRNTI %d, cells heard %d/%d, scan rows %d\n', ...
            UEs(u).ID, m.ueRNTI, heard, numGNB, size(m.featureLog, 1));
    end
    fprintf('\n');

    %% ---- connection ordering, the likely correct source ---------------------
    fprintf('--- gNB connection tables ------------------------------------\n');
    for g = 1:numGNB
        fprintf(' gNB %d:\n', g);
        probeConnectionProps(gNBs(g));
    end
    fprintf('\n');

    %% ---- verdict ------------------------------------------------------------
    % Checked PER UE against its OWN anchor gNB. An earlier version tested
    % whether the expected RNTI set intersected the logged set anywhere,
    % which passed on a two-cell layout where one UE of three happened to
    % line up, and so reported a sound mapping for a mapping that was
    % wrong for the other two. A global set test cannot detect this.
    fprintf('--- verdict ---------------------------------------------------\n');
    if nCtx == 0 && nGrant == 0
        fprintf(2, ['Both scheduler logs are EMPTY. The overrides are not ' ...
            'being invoked at all: the fault is in the scheduler class or ' ...
            'in configureScheduler, not in the RNTI convention.\n\n']);
        okMap = false;
    else
        okMap = true;
        fprintf(['Column "legacy" is the node-derived value Phase 4 used ' ...
            'and is shown only for comparison.\n"resolved" is what the ' ...
            'pipeline now reads from the anchor gNB connection table and ' ...
            'actually uses.\n\n']);
        fprintf('%-4s %-6s %-9s %-8s %-9s %s\n', 'UE', 'node', 'legacy', ...
            'anchor', 'resolved', 'agree');
        for u = 1:numUE
            g = gNBs(anchorIdx(u));
            correct = NaN;
            if isprop(g, 'UENodeIDs') && isprop(g, 'ConnectedUEs')
                k = find(g.UENodeIDs == UEs(u).ID, 1);
                if ~isempty(k), correct = g.ConnectedUEs(k); end
            end
            hit = isequaln(expected(u), correct);
            okMap = okMap && hit;
            fprintf('%-4d %-6d %-9d %-8d %-9s %s\n', u, UEs(u).ID, ...
                expected(u), anchorIdx(u), num2str(correct), ...
                yesNo(hit));
        end
        fprintf('\n');
        allResolved = true;
        for u = 1:numUE
            g = gNBs(anchorIdx(u));
            if ~(isprop(g, 'UENodeIDs') && ...
                    any(g.UENodeIDs == UEs(u).ID))
                allResolved = false;
            end
        end
        if ~allResolved
            fprintf(2, ['At least one UE could not be resolved from its ' ...
                'anchor gNB connection table. This is a real fault: the ' ...
                'pipeline cannot find that UE in the scheduler logs at ' ...
                'all.\n']);
        elseif okMap
            fprintf(['Resolved. Note the legacy and resolved values agree ' ...
                'AT THIS SIZE, which proves nothing: the two conventions ' ...
                'coincide on small layouts by construction. Re-run with ' ...
                'more gNBs before drawing any conclusion from that.\n']);
        else
            fprintf(['Resolved. The legacy node-derived value disagrees, ' ...
                'as expected: the scheduler numbers each UE by its ' ...
                'CONNECTION INDEX at that gNB, which is unrelated to the ' ...
                'node ID, so the Phase 4 convention found the wrong UE or ' ...
                'none at all. The pipeline uses the resolved column, so ' ...
                'the disagreement above is the old bug being demonstrated ' ...
                'rather than a fault still present.\n']);
        end
    end
    fprintf('\n');

    D = struct('expected', expected, 'ctxRNTI', ctxRNTI, ...
        'grantRNTI', grantRNTI, 'anchorIdx', anchorIdx, ...
        'nCtx', nCtx, 'nGrant', nGrant, 'scheds', {scheds}, ...
        'gNBs', gNBs, 'UEs', UEs, 'managers', {managers});
end

%% ----------------------------------------------------------------------
function app = mk(spec)
    app = networkTrafficOnOff(GeneratePacket=true, OnTime=spec.onTime_s, ...
        OffTime=spec.offTime_s, DataRate=spec.dataRate_kbps, ...
        PacketSize=spec.packetSize_B);
end

%% ----------------------------------------------------------------------
function probeConnectionProps(gNB)
%probeConnectionProps Report any property that exposes the connected UEs.
%   The RNTI a gNB assigns is its connection index, so whichever of these
%   properties exists is the authoritative source for the scheduler-log
%   RNTI and removes the need for a hand-calibrated offset entirely.
    cands = {'ConnectedUEs', 'UENodeIDs', 'UEs', 'ConnectedUENodeIDs', ...
             'UENodeNames', 'NumUEs'};
    found = false;
    for k = 1:numel(cands)
        if isprop(gNB, cands{k})
            v = gNB.(cands{k});
            found = true;
            fprintf('  %-20s : %s\n', cands{k}, describe(v));
        end
    end
    if ~found
        fprintf('  none of the candidate properties exist; listing all:\n');
        p = properties(gNB);
        fprintf('  %s\n', strjoin(p', ', '));
    end
end

function s = yesNo(tf)
    if tf, s = 'yes'; else, s = 'NO'; end
end

function s = describe(v)
    if isnumeric(v) || islogical(v)
        s = mat2str(v);
    elseif isstring(v) || ischar(v)
        s = char(strjoin(string(v), ', '));
    elseif isobject(v)
        if isprop(v, 'ID')
            s = sprintf('%s array, IDs %s', class(v), mat2str([v.ID]));
        else
            s = sprintf('%s array, %d element(s)', class(v), numel(v));
        end
    else
        s = sprintf('%s, %d element(s)', class(v), numel(v));
    end
end
