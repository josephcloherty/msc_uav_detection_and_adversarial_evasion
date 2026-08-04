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
%   Analysis only; this must never enter the CSV. A wide pLOSmin/pLOSmax
%   range with zero transitions means a frozen state.
%
%   SAMPLERATEHZ (default 5) decimates the 100 Hz position trace. The state
%   cannot change faster than the UE crosses a correlation cell, about 1.7 s
%   at 30 m/s; raise it if the correlation distance is set far below standard.

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

    % find() inside the frame loop would make this quadratic.
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

        % Each sampled instant maps to the last featureLog row at or before
        % it. Duplicate timestamps are collapsed first, since discretize
        % needs strictly increasing edges.
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
