function configureULforSRS(UE, gNBs)
%configureULforSRS Dedicated UL links for SRS measurement at non-serving gNBs
%
%   configureULforSRS(UE, GNBS) gives the UE an uplink to each non-serving
%   gNB, used only for SRS, so every cell measures its uplink SINR.
%   Without this a UE yields SINR at its serving gNB only.
%
%   Call this before the serving connectUE, or that call errors with "UE is
%   already connected to the gNB".
%
%   Assumes gNBs(1) serves and connects to gNBs(2:end); change servingIdx if
%   a different gNB serves.
%
%   Reconstructed from arXiv:2509.00868 Section II rather than taken from the
%   Fudan repo, so check h.ulSINR is populated for multiple gNBs after a run.

    servingIdx = 1;  % gNBs(1) is the serving cell, connected separately
    rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);

    for i = 1:numel(gNBs)
        if i == servingIdx
            continue;   % leave the serving gNB for the caller's own connectUE
        end
        connectUE(gNBs(i), UE, RLCBearerConfig=rlcBearerConfig);
    end
end