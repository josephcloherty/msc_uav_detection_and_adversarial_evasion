function report = losDiagnostics(posLog, managers, cfg, linkInfo, sampleRateHz)
%losDiagnostics Per-UE LOS state summary over a completed run.
%
%   REPORT = losDiagnostics(POSLOG, MANAGERS, CFG, LINKINFO) walks the
%   recorded position trace and evaluates linkState towards each UE's
%   CURRENT serving cell, returning a per-UE summary:
%       .ueID            UE node ID
%       .label           "aerial" or "terrestrial"
%       .losFraction     fraction of recorded instants in LOS
%       .transitions     number of LOS <-> NLOS changes
%       .pLOSmin/.pLOSmax  range swept by the Table B-1 probability
%       .dynamic         whether the state came from the spatially
%                        consistent field or the frozen setup-time draw
%
%   WHY THIS EXISTS, AND WHY IT IS NOT A FEATURE
%   --------------------------------------------
%   LOS state is not observable by an operator, and in this scenario set
%   it is near-collinear with the aerial label (Table B-1 gives pLOS = 1
%   above 100 m in UMa). It must therefore never enter the feature CSV,
%   or every Phase 6 classifier score becomes meaningless. It is still
%   worth having for ANALYSIS - to confirm the channel is behaving, to
%   report LOS statistics in the write-up, and specifically to verify that
%   the Phase 5 dynamic state actually moves.
%
%   .transitions is the direct check. Before Phase 5 the state was drawn
%   once from the initial positions and frozen, so this count was zero for
%   every UE in every run by construction, while .pLOSmin and .pLOSmax
%   showed the probability sweeping its full range. A run with a wide
%   pLOS range and zero transitions is the frozen-state signature.
%
%   The result is plain data (a struct array of scalars and strings), so
%   it crosses back from a parallel worker cheaply and can be stored in
%   the replay bundle without bloating it.
%
%   SAMPLERATEHZ (default 5) decimates the position trace before
%   evaluating. The recorder runs at 100 Hz, so a five-minute run holds
%   30 000 frames per node; evaluating every frame for every UE would cost
%   far more than the diagnostic is worth. The LOS state cannot change
%   faster than the UE crosses a correlation cell, which at the 50-60 m
%   correlation distances of Table 7.6.3.1-2 and a 30 m/s aerial speed is
%   about 1.7 s, so 5 Hz oversamples the fastest possible transition by an
%   order of magnitude. Raise it if the correlation distance is ever
%   configured far below the standard values.

    if nargin < 5 || isempty(sampleRateHz), sampleRateHz = 5; end

    report = struct('ueID', {}, 'label', {}, 'losFraction', {}, ...
        'transitions', {}, 'pLOSmin', {}, 'pLOSmax', {}, 'dynamic', {});

    if isempty(posLog) || ~isfield(posLog, 'times') || isempty(posLog.times)
        return;
    end

    allTimes = posLog.times(:);
    if numel(allTimes) < 2
        frameIdx = 1;
    else
        recRate = 1 / median(diff(allTimes));
        stride = max(1, round(recRate / sampleRateHz));
        frameIdx = 1:stride:numel(allTimes);
    end
    times = allTimes(frameIdx);

    % gNB node ID -> row in the position log, precomputed. Doing this with
    % find() inside the frame loop turned the whole function quadratic.
    nodeRowByID = zeros(1, max(posLog.nodeIDs));
    nodeRowByID(posLog.nodeIDs) = 1:numel(posLog.nodeIDs);

    for k = 1:numel(managers)
        m = managers{k};
        fl = m.featureLog;
        ueID = m.UE.ID;
        if ueID > numel(nodeRowByID) || nodeRowByID(ueID) == 0 || isempty(fl)
            continue;
        end
        uRow = nodeRowByID(ueID);

        cTime  = strcmp(m.featureNames, 'time');
        cSrvID = strcmp(m.featureNames, 'servingGNB');

        % Map every sampled instant to the last featureLog row at or
        % before it, in one vectorised pass instead of a find() per frame.
        % Duplicate scan timestamps are collapsed first, because discretize
        % requires strictly increasing edges and would otherwise error on a
        % run where two scans happened to land on the same simulated time.
        flTimes = fl(:, cTime);
        [uT, iu] = unique(flTimes, 'last');
        rowOf = discretize(times, [uT(:); Inf]);
        ok = ~isnan(rowOf);
        rowOf(ok) = iu(rowOf(ok));

        states = nan(numel(times), 1);
        pl     = nan(numel(times), 1);
        dynAny = false;

        for ii = 1:numel(times)
            r = rowOf(ii);
            if isnan(r), continue; end
            gID = fl(r, cSrvID);
            if isnan(gID) || gID < 1 || gID > numel(nodeRowByID) ...
                    || nodeRowByID(gID) == 0
                continue;
            end
            f = frameIdx(ii);

            gP = reshape(posLog.xyz(nodeRowByID(gID), :, f), 1, 3);
            uP = reshape(posLog.xyz(uRow, :, f), 1, 3);

            st = linkState(linkInfo, cfg, gID, ueID, gP, uP);
            states(ii) = double(st.isLOS);
            pl(ii) = st.pLOS;
            dynAny = dynAny || st.dynamic;
        end

        sv = states(~isnan(states));
        pv = pl(~isnan(pl));
        if isempty(sv), continue; end

        e = struct();
        e.ueID        = ueID;
        e.label       = string(m.ueLabel);
        e.losFraction = mean(sv);
        e.transitions = sum(diff(sv) ~= 0);
        e.pLOSmin     = min(pv);
        e.pLOSmax     = max(pv);
        e.dynamic     = dynAny;
        report(end+1) = e; %#ok<AGROW>
    end
end
