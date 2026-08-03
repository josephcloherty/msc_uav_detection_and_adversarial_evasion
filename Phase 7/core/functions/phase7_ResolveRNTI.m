function map = phase5_ResolveRNTI(cfg, gNBs, UEs, anchorIdx, printMap)
%phase5_ResolveRNTI Resolve and check both RNTI conventions before a run.
%
%   MAP = phase5_ResolveRNTI(CFG, GNBS, UES, ANCHORIDX, PRINTMAP)
%   returns a struct with one entry per UE recording both identifiers the
%   pipeline needs, and validates everything that can be validated before
%   the simulation starts. Called by phase5_Pipeline for every run, so no
%   batch can start on an unverified mapping.
%
%   TWO CONVENTIONS, NOT ONE
%   ------------------------
%   MAP.sched  the RNTI the SCHEDULER logs use. This is the UE's
%              connection index at its anchor gNB, read from that gNB's
%              own UENodeIDs and ConnectedUEs tables. Derived, never
%              assumed, so it cannot drift with gNB count, UE count or
%              attachment order. Diagnostics on 21 July confirmed each
%              gNB lists only the UEs anchored to it, and that every UE
%              appears in its own anchor's table.
%
%   MAP.srs    the RNTI carried by SRS reception events, which the
%              handover managers filter on. This one IS node derived,
%              empirically UE.ID + cfg.rntiOffset, and it genuinely
%              remains a hand-calibrated constant: the offset of -2 has
%              held at three, five and seven gNBs, but nothing in the
%              toolbox guarantees it. It cannot be checked here because
%              no SRS event exists until the simulation runs, so it is
%              checked in flight by rntiVerifier instead.
%
%   CHECKS PERFORMED HERE (all pre-run, all cheap)
%     - the connection tables exist on this release
%     - every UE appears in its anchor gNB's table, exactly once
%     - no two UEs at the same anchor resolve to the same scheduler RNTI
%     - the anchor index and the toolbox agree on where each UE attached
%
%   The Phase 2 and Phase 3 practice was to calibrate the offset by hand
%   and carry the number forward. That is what allowed a value correct
%   for three gNBs to be used silently at seven, so the check is done per
%   run from here on rather than once per phase.

    if nargin < 5 || isempty(printMap), printMap = true; end

    numUE = numel(UEs);
    map = struct();
    map.sched   = zeros(1, numUE);
    map.srs     = [UEs.ID] + cfg.rntiOffset;
    map.ueID    = [UEs.ID];
    map.anchor  = anchorIdx;
    map.offset  = cfg.rntiOffset;

    for u = 1:numUE
        g = gNBs(anchorIdx(u));
        assert(isprop(g, 'UENodeIDs') && isprop(g, 'ConnectedUEs'), ...
            'phase5_ResolveRNTI:noConnectionTable', ...
            ['nrGNB exposes neither UENodeIDs nor ConnectedUEs on this ' ...
             'release, so the scheduler RNTI cannot be resolved. Run ' ...
             'phase5_SchedulerDiag to list the available properties and ' ...
             'update this function rather than reverting to an offset.']);

        k = find(g.UENodeIDs == UEs(u).ID);
        assert(~isempty(k), 'phase5_ResolveRNTI:ueNotAtAnchor', ...
            ['UE %d (node %d) is absent from the connection table of ' ...
             'its anchor gNB %d. The pipeline''s anchor bookkeeping and ' ...
             'the toolbox disagree, which would silently empty this ' ...
             'UE''s CQI, MCS and traffic columns.'], u, UEs(u).ID, anchorIdx(u));
        assert(isscalar(k), 'phase5_ResolveRNTI:duplicateEntry', ...
            ['UE %d (node %d) appears %d times in the connection table ' ...
             'of gNB %d.'], u, UEs(u).ID, numel(k), anchorIdx(u));

        map.sched(u) = g.ConnectedUEs(k);
    end

    % Two UEs on the same anchor must not share a scheduler RNTI, or one
    % would silently absorb the other's CQI, MCS and grants.
    for g = unique(anchorIdx)
        sel = anchorIdx == g;
        r = map.sched(sel);
        assert(numel(unique(r)) == numel(r), ...
            'phase5_ResolveRNTI:collidingRNTI', ...
            ['Two or more UEs anchored at gNB %d resolve to the same ' ...
             'scheduler RNTI (%s). Their scheduler observables would be ' ...
             'merged.'], g, mat2str(r));
    end

    if printMap
        fprintf(['RNTI map [%s seed %d]  %d gNB, %d UE  (SRS offset %+d, ' ...
            'verified in flight)\n'], cfg.scenario, cfg.seed, ...
            numel(gNBs), numUE, cfg.rntiOffset);
        fprintf('  %-4s %-6s %-7s %-8s %-11s %s\n', ...
            'UE', 'node', 'class', 'anchor', 'schedRNTI', 'srsRNTI');
        for u = 1:numUE
            if cfg.ueIsAerial(u), cls = 'aerial'; else, cls = 'terr'; end
            fprintf('  %-4d %-6d %-7s %-8d %-11d %d\n', u, UEs(u).ID, ...
                cls, anchorIdx(u), map.sched(u), map.srs(u));
        end
    end
end
