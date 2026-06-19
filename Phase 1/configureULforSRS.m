function configureULforSRS(UE, gNBs)
%configureULforSRS Establish dedicated UL links for SRS measurement at non-serving gNBs
%
%   configureULforSRS(UE, GNBS) connects the UE to each NON-SERVING gNB in
%   GNBS via a dedicated uplink link used only for SRS transmission, so
%   that every gNB (not just the serving cell) receives the UE's SRS and
%   measures its uplink SINR. This is the mechanism the paper describes to
%   work around MATLAB's limitation that a UE otherwise only yields SINR
%   at its serving gNB. The handover manager reads these per-gNB SINR
%   values from PacketReceptionEnded SRS events to drive A3 handover.
%
%   The serving connection (connectUE to the chosen serving gNB) is done
%   SEPARATELY by the calling script AFTER this function runs. This
%   function therefore must NOT connect the UE to the gNB that will become
%   the serving cell, or the later serving connectUE will error with
%   "UE is already connected to the gNB".
%
%   ASSUMPTION matching the repo scripts (baseNetwork.m etc.): the serving
%   gNB for the UE is gNBs(1). This helper connects the UE to gNBs(2:end)
%   only. If your script uses a different serving gNB, change servingIdx.
%
%   ---------------------------------------------------------------------
%   RECONSTRUCTED HELPER. Not committed to the Fudan repo. Reconstructed
%   from the paper (arXiv:2509.00868, Section II handover description) and
%   the handover manager's SINR-collection path. The paper states the UE
%   establishes dedicated UL links to each non-serving gNB for SRS, and
%   each gNB configures SRS reception in MAC/PHY to decode it. VERIFY that
%   h.ulSINR is populated for multiple gNBs after a run. Log in
%   deviations_log.md.
%   ---------------------------------------------------------------------

    servingIdx = 1;  % gNBs(1) is the serving cell, connected separately
    rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);

    for i = 1:numel(gNBs)
        if i == servingIdx
            continue;   % leave the serving gNB for the script's own connectUE
        end
        connectUE(gNBs(i), UE, RLCBearerConfig=rlcBearerConfig);
    end
end