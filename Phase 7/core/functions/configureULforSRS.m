function configureULforSRS(UE, gNBs)
%configureULforSRS Dedicated UL links for SRS measurement at non-serving gNBs
%
%   configureULforSRS(UE, GNBS) gives the UE an uplink to each non-serving
%   gNB, used only for SRS, so every cell measures its uplink SINR. Without
%   it a UE yields SINR at its serving gNB only.
%
%   Call this before the serving connectUE, or that call errors with "UE is
%   already connected to the gNB". Assumes gNBs(1) serves.
%
%   Reconstructed from arXiv:2509.00868 Section II.

    servingIdx = 1;  % connected separately by the caller
    rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);

    for i = 1:numel(gNBs)
        if i == servingIdx
            continue;
        end
        connectUE(gNBs(i), UE, RLCBearerConfig=rlcBearerConfig);
    end
end