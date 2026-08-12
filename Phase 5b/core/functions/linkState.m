function st = linkState(linkInfo, cfg, gnbID, ueID, gnbPos, uePos)
%linkState Live LOS state and shadow fading for one gNB-UE link.
%
%   ST = linkState(LINKINFO, CFG, GNBID, UEID, GNBPOS, UEPOS) returns the
%   link state at the CURRENT node positions:
%       ST.pLOS    Table B-1 / Table 7.4.2-1 LOS probability at (hUT, d2D)
%       ST.isLOS   the drawn LOS state (logical)
%       ST.sfDB    lognormal shadow-fading term in dB (0 when disabled)
%       ST.dynamic true when the state came from the spatially-consistent
%                  field, false when it fell back to the setup-time draw
%       ST.d2D, ST.d3D, ST.hUT  the geometry the state was evaluated at
%
%   Called by both the runtime pathloss and the replay renderer, so the two
%   cannot disagree.
%
%   The state is the threshold test isLOS = U(x, y) < pLOS(hUT, d2D), where U
%   is a spatially-consistent uniform field with the Table 7.6.3.1-2
%   correlation distance, one independent field per gNB. pLOS uses the live
%   height and distance.
%
%   Shadow fading follows the live state, so a transition steps the
%   shadow-fading term; that discontinuity is in the deviations log. With no
%   field in LINKINFO this falls back to the setup-time draw.
%
%   See also buildSpatialField, sampleSpatialField, createScenarioChannels.

    uePos = uePos(:).';
    gnbPos = gnbPos(:).';

    d2D = max(norm(uePos(1:2) - gnbPos(1:2)), 1);
    d3D = max(norm(uePos - gnbPos), 1);
    hUT = uePos(3);

    st = struct('pLOS', NaN, 'isLOS', false, 'sfDB', 0, ...
        'dynamic', false, 'd2D', d2D, 'd3D', d3D, 'hUT', hUT);

    st.pLOS = tr36777LOSProbability(cfg.scenario, hUT, d2D);

    gIdx = 0;
    if isfield(linkInfo, 'gnbIdxByID') && gnbID <= numel(linkInfo.gnbIdxByID)
        gIdx = linkInfo.gnbIdxByID(gnbID);
    end

    hasField = isfield(linkInfo, 'losField') && ~isempty(linkInfo.losField) ...
        && gIdx >= 1;

    if hasField
        u = sampleSpatialField(linkInfo.losField, gIdx, uePos(1), uePos(2));
        st.isLOS = u < st.pLOS;
        st.dynamic = true;
    else
        % Frozen setup-time draw: archived run, or dynamic LOS off.
        st.isLOS = linkInfo.los(gnbID, ueID);
        st.sfDB  = linkInfo.sf(gnbID, ueID);
        return;
    end

    % sigma is selected by the live state.
    if isfield(cfg, 'enableShadowFading') && cfg.enableShadowFading
        if isfield(linkInfo, 'sfField') && ~isempty(linkInfo.sfField)
            if st.isLOS, which = 1; else, which = 2; end
            [~, z] = sampleSpatialField(linkInfo.sfField{which}, gIdx, ...
                uePos(1), uePos(2));
            sigma = tr36777ShadowFadingStd(cfg.scenario, st.isLOS, hUT, ...
                cfg.zBoundary);
            st.sfDB = sigma * z;
        else
            st.sfDB = linkInfo.sf(gnbID, ueID);
        end
    end
end
