function report = losDiagnostics(posLog, managers, cfg, linkInfo, sampleRateHz)
% walks a recorded position trace and summarises each UE's LOS state towards
% its serving cell. analysis only, never a feature.

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

    % precompute gNB row lookup
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

        % map sampled instants to feature rows
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
