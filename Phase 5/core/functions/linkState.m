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
%   THIS IS THE SINGLE SOURCE OF TRUTH for LOS state. Both the runtime
%   pathloss (tr36777ChannelModel) and the replay renderer call it, so the
%   colour of a link in the replay is by construction the state the
%   simulator used. The previous split - pathloss reading a frozen
%   linkInfo.los while the replay annotation recomputed pLOS live - is
%   what made a static LOS state look like a rendering bug.
%
%   Dynamic state (TR 38.901 clause 7.6.3.1/7.6.3.3)
%   -----------------------------------------------
%   The LOS state is the threshold test
%       isLOS = U(x, y) < pLOS(hUT, d2D)
%   where U is a spatially-consistent uniform field with the correlation
%   distance of Table 7.6.3.1-2 (50 m UMa/UMi, 60 m RMa), one independent
%   field per gNB. Because U is a pure function of position, a UE flying
%   through the cell transitions LOS -> NLOS -> LOS on the correct spatial
%   scale instead of flickering per packet, and two UEs at the same place
%   see the same state for a given cell.
%
%   pLOS is evaluated at the LIVE height and 2D distance, so the altitude
%   dependence of Table B-1 is tracked as well: a UE climbing above 100 m
%   in UMa reaches pLOS = 1 and latches to LOS, which is exactly the
%   behaviour the frozen draw could not reproduce.
%
%   Shadow fading follows the live state: sigma is re-read from
%   tr36777ShadowFadingStd for the current LOS/NLOS branch and multiplies
%   a second spatially-consistent normal field with the Table 7.6.3.1-2 SF
%   correlation distance for that branch. A LOS transition therefore steps
%   the shadow-fading term, which is the physically correct consequence of
%   a state change but is a discontinuity; noted in the deviations log.
%
%   Backward compatibility: when LINKINFO carries no field (an archived
%   Phase 4 replay, or cfg.dynamicLOS false) the function returns the
%   setup-time draw from LINKINFO.los / LINKINFO.sf with ST.dynamic false.
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
        % Frozen setup-time draw (archived runs, or dynamic LOS disabled)
        st.isLOS = linkInfo.los(gnbID, ueID);
        st.sfDB  = linkInfo.sf(gnbID, ueID);
        return;
    end

    % ---- shadow fading, sigma selected by the LIVE state ----------------
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
