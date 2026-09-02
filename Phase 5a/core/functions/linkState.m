function st = linkState(linkInfo, cfg, gnbID, ueID, gnbPos, uePos)
% returns the live LOS state and shadow fading for one gNB-UE link at the
% current node positions, so pathloss and replay always agree.

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
        % frozen setup-time draw
        st.isLOS = linkInfo.los(gnbID, ueID);
        st.sfDB  = linkInfo.sf(gnbID, ueID);
        return;
    end

    % shadow fading, sigma from the live state
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
