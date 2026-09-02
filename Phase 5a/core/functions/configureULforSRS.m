function configureULforSRS(UE, gNBs)
% connects the UE to every non-serving gNB over a dedicated uplink so each
% cell receives its SRS and reports an uplink SINR. the serving connection is
% made separately by the caller, so gNBs(1) is skipped here.

    servingIdx = 1;  % serving cell
    rlcBearerConfig = nrRLCBearerConfig(SNFieldLength=6, BucketSizeDuration=10);

    for i = 1:numel(gNBs)
        if i == servingIdx
            continue;   % skip serving gNB
        end
        connectUE(gNBs(i), UE, RLCBearerConfig=rlcBearerConfig);
    end
end