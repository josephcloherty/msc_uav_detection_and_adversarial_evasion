function map = phase7_ResolveRNTI(cfg, gNBs, UEs, anchorIdx, printMap)
%phase7_ResolveRNTI Resolve and check both RNTI conventions before a run.
%
%   MAP = phase7_ResolveRNTI(CFG, GNBS, UES, ANCHORIDX, PRINTMAP) returns one
%   entry per UE for both identifiers the pipeline needs, and validates
%   whatever can be validated before the simulation starts.
%
%   There are two conventions, and they are easy to confuse:
%     MAP.sched  the RNTI the scheduler logs use, read from the anchor gNB's
%                own UENodeIDs and ConnectedUEs tables and so never assumed
%     MAP.srs    the RNTI on SRS reception events, which is node derived as
%                UE.ID + cfg.rntiOffset and still hand-calibrated
%
%   The SRS one cannot be checked here because no event exists yet, so
%   rntiVerifier checks it in flight.
%
%   Checks done here, all cheap:
%     - the connection tables exist on this release
%     - every UE appears in its anchor gNB's table, exactly once
%     - no two UEs at the same anchor share a scheduler RNTI
%     - the anchor index and the toolbox agree on where each UE attached

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
            'phase7_ResolveRNTI:noConnectionTable', ...
            ['nrGNB exposes neither UENodeIDs nor ConnectedUEs on this ' ...
             'release, so the scheduler RNTI cannot be resolved. Run ' ...
             'phase7_SchedulerDiag to list the available properties and ' ...
             'update this function rather than reverting to an offset.']);

        k = find(g.UENodeIDs == UEs(u).ID);
        assert(~isempty(k), 'phase7_ResolveRNTI:ueNotAtAnchor', ...
            ['UE %d (node %d) is absent from the connection table of ' ...
             'its anchor gNB %d. The pipeline''s anchor bookkeeping and ' ...
             'the toolbox disagree, which would silently empty this ' ...
             'UE''s CQI, MCS and traffic columns.'], u, UEs(u).ID, anchorIdx(u));
        assert(isscalar(k), 'phase7_ResolveRNTI:duplicateEntry', ...
            ['UE %d (node %d) appears %d times in the connection table ' ...
             'of gNB %d.'], u, UEs(u).ID, numel(k), anchorIdx(u));

        map.sched(u) = g.ConnectedUEs(k);
    end

    % If two UEs on one anchor shared an RNTI, one would silently absorb the
    % other's CQI, MCS and grants.
    for g = unique(anchorIdx)
        sel = anchorIdx == g;
        r = map.sched(sel);
        assert(numel(unique(r)) == numel(r), ...
            'phase7_ResolveRNTI:collidingRNTI', ...
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
