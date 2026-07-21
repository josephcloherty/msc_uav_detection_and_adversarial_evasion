function phase4SchedulerCheck()
%phase4SchedulerCheck D4.1 verification of the custom scheduler route (R2024b).
%
%   Run ONCE on R2024b before trusting any Phase 4 output, then record the
%   printed findings in the logbook/deviations log (the plan requires the
%   check to be logged either way). The reference is the MathWorks example
%   "Use Custom Scheduler in 5G System-Level Simulation".
%
%   Checks, in order:
%     A. Release + native-logging check: the no-native-CQI-logging
%        conclusion was reached against R2026a docs; confirm it holds on
%        R2024b by inspecting the public statistics() trees of a gNB and a
%        UE for any CQI/MCS time series (expected: none; only aggregate
%        counters).
%     B. configureScheduler accepts a cqiLoggingScheduler instance
%        (custom nrScheduler subclass) BEFORE connectUE.
%     C. A 2 s single-gNB probe run:
%          - the overridden methods are invoked (grantLog non-empty),
%          - superclass delegation returns valid assignments (grants
%            carry MCS indices in 0-28 and non-zero RB counts),
%          - UEContext exposes DL CQI (ctxLog wbCQI not all-NaN, values
%            in 0-15) and the SRS-derived UL MCS estimate,
%          - scheduler-log RNTIs match the UE.ID + offset convention the
%            handover managers use (needed by extractWindowedFeatures),
%          - statistics(ue) is callable mid-run (trafficSampler route)
%            and the MAC/App byte fields exist under the expected names.
%
%   Every check prints PASS/FAIL plus what was actually found, so a
%   failed probe documents the R2024b layout for the deviations log
%   rather than erroring opaquely.

    addpath(fullfile(fileparts(mfilename('fullpath')), 'functions'));
    fprintf('=== Phase 4 D4.1 scheduler-route check ===\n');
    fprintf('MATLAB release: %s\n', version('-release'));
    assert(strcmp(version('-release'), '2024b'), ...
        'phase4SchedulerCheck:release', ...
        'This check documents R2024b behaviour; run it on R2024b.');

    %% --- B + C: probe scenario (1 gNB, 2 UEs, 2 s) -----------------------
    % The probe runs SISO (single antenna at both ends): the simulator's
    % default channel supports SISO only, and this check needs no custom
    % channel because it verifies the scheduler API and the CSI field
    % layout, neither of which depends on antenna count. The full
    % pipeline keeps the Phase 3 MIMO configuration; it adds the
    % TR 36.777 custom channel model, so the SISO restriction never
    % applies there. (Found on the first R2024b run of this check.)
    rng(1);
    sim = wirelessNetworkSimulator.init;
    gnb = nrGNB(Name="chk-gNB", Position=[0 0 25], ...
        CarrierFrequency=2.6e9, ChannelBandwidth=20e6, ...
        SubcarrierSpacing=30e3, NumTransmitAntennas=1, ...
        NumReceiveAntennas=1, ReceiveGain=11, DuplexMode="TDD");

    sched = cqiLoggingScheduler;
    try
        configureScheduler(gnb, Scheduler=sched);
        fprintf('PASS  B: configureScheduler accepted the custom subclass.\n');
    catch ME
        fprintf('FAIL  B: configureScheduler rejected the subclass: %s\n', ME.message);
        rethrow(ME);
    end

    ues = nrUE(Name=["chk-UE-1" "chk-UE-2"], ...
        Position=[50 0 1.5; -80 40 1.5], ...
        NumTransmitAntennas=1, NumReceiveAntennas=1, ReceiveGain=11);
    connectUE(gnb, ues, ...
        RLCBearerConfig=nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10));
    addNodes(sim, gnb); addNodes(sim, ues);

    for u = 1:numel(ues)
        ulApp = networkTrafficOnOff(GeneratePacket=true, OnTime=Inf, ...
            OffTime=0, DataRate=1000);
        addTrafficSource(ues(u), ulApp);
        dlApp = networkTrafficOnOff(GeneratePacket=true, OnTime=Inf, ...
            OffTime=0, DataRate=1000);
        addTrafficSource(gnb, dlApp, DestinationNode=ues(u));
    end

    % Mid-run statistics() probe (the trafficSampler access pattern)
    midRunOK = false; midRunErr = '';
    function probeStats(~, ~)
        try
            s = statistics(ues(1));
            assert(isfield(s, 'App') && isfield(s.App, 'TransmittedBytes'));
            assert(isfield(s, 'MAC') && isfield(s.MAC, 'TransmittedBytes'));
            midRunOK = true;
        catch ME2
            midRunErr = ME2.message;
        end
    end
    scheduleAction(sim, @probeStats, [], 1, 1);

    run(sim, 2);

    %% --- C: inspect the logs --------------------------------------------
    [ctx, grants] = sched.getLogs();

    if isempty(grants)
        fprintf(['FAIL  C1: grantLog empty; the overridden methods were not\n' ...
                 '          invoked or delegation returned nothing. Check the\n' ...
                 '          method names against the R2024b custom scheduler\n' ...
                 '          example before proceeding.\n']);
    else
        okMCS = all(grants(:,4) >= 0 & grants(:,4) <= 28 | isnan(grants(:,4)));
        okRB  = any(grants(:,5) > 0);
        fprintf('%s  C1: %d grants logged; MCS in range: %d; RB counts present: %d.\n', ...
            tern(okMCS && okRB, 'PASS', 'FAIL'), size(grants,1), okMCS, okRB);
    end

    if isempty(ctx)
        fprintf('FAIL  C2: ctxLog empty; UEContext snapshotting never ran.\n');
    else
        cqiVals = ctx(~isnan(ctx(:,3)), 3);
        ulVals  = ctx(~isnan(ctx(:,5)), 5);
        fprintf('%s  C2: DL CQI present for %d/%d snapshots (range %s); ', ...
            tern(~isempty(cqiVals) && all(cqiVals >= 0 & cqiVals <= 15), ...
                'PASS', 'FAIL'), ...
            numel(cqiVals), size(ctx,1), rangeStr(cqiVals));
        fprintf('UL MCS ctx present for %d snapshots (range %s).\n', ...
            numel(ulVals), rangeStr(ulVals));
        if isempty(cqiVals)
            fprintf('      C2 diagnosis: actual layout of UEContext(1).CSIMeasurementDL\n');
            fprintf('      (record this in the deviations log):\n');
            try
                printTree(sched.UEContext(1).CSIMeasurementDL, ...
                    '        CSIMeasurementDL', 0);
            catch ME3
                fprintf('        <UEContext dump failed: %s>\n', ME3.message);
            end
        end

        % RNTI convention: with a single gNB and this connection order the
        % scheduler RNTIs should be 1..numUE; the manager convention maps
        % UE.ID + cfg.rntiOffset onto the SAME values (probe any full
        % scenario with tools/rntiOffsetCalculator.m).
        r = unique(ctx(:,2))';
        fprintf('%s  C3: scheduler-log RNTIs = [%s] (expected 1..%d).\n', ...
            tern(isequal(r, 1:numel(ues)), 'PASS', 'CHECK'), ...
            strtrim(sprintf('%d ', r)), numel(ues));
    end

    fprintf('%s  C4: statistics(ue) mid-run with expected App/MAC byte fields.%s\n', ...
        tern(midRunOK, 'PASS', 'FAIL'), tern(midRunOK, '', [' Error: ' midRunErr]));

    %% --- A: native-logging check (public API surface) --------------------
    gs = statistics(gnb); us = statistics(ues(1));
    hits = [findCQIFields(gs, 'statistics(gNB)'), findCQIFields(us, 'statistics(UE)')];
    if isempty(hits)
        fprintf(['PASS  A: no CQI/MCS time series in the public statistics()\n' ...
                 '         trees on R2024b; the R2026a-era no-native-CQI-logging\n' ...
                 '         conclusion HOLDS and the custom scheduler is required.\n']);
    else
        fprintf(['CHECK A: possible native CQI/MCS fields found: %s.\n' ...
                 '         Inspect before keeping the custom route; log either way.\n'], ...
            strjoin(hits, ', '));
    end

    fprintf('=== Check complete: paste this output into the logbook. ===\n');
end

%% local helpers
function s = tern(c, a, b)
    if c, s = a; else, s = b; end
end

function s = rangeStr(v)
    if isempty(v), s = 'n/a'; else, s = sprintf('%g..%g', min(v), max(v)); end
end

function printTree(s, prefix, depth)
%printTree Recursive one-line-per-field dump: name, class, size, and the
% value itself when it is a small numeric array.
    if depth > 4
        fprintf('%s ...\n', prefix);
        return;
    end
    if ~isstruct(s)
        fprintf('%s: %s %s\n', prefix, class(s), mat2str(size(s)));
        return;
    end
    s = s(1);
    f = fieldnames(s);
    for i = 1:numel(f)
        v = s.(f{i});
        p = [prefix '.' f{i}];
        if isstruct(v)
            fprintf('%s (struct %s)\n', p, mat2str(size(v)));
            printTree(v, p, depth + 1);
        elseif isnumeric(v) && numel(v) <= 8
            fprintf('%s = %s\n', p, mat2str(v));
        else
            fprintf('%s: %s %s\n', p, class(v), mat2str(size(v)));
        end
    end
end

function hits = findCQIFields(s, prefix)
%findCQIFields Recursively list field paths whose names mention CQI/MCS.
    hits = {};
    if ~isstruct(s), return; end
    f = fieldnames(s);
    for i = 1:numel(f)
        p = [prefix '.' f{i}];
        if ~isempty(regexpi(f{i}, 'cqi|mcs', 'once'))
            hits{end+1} = p; %#ok<AGROW>
        end
        v = s.(f{i});
        if isstruct(v) && isscalar(v)
            hits = [hits, findCQIFields(v, p)]; %#ok<AGROW>
        end
    end
end
