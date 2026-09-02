function channel = buildAerialCDL(link)
% builds the CDL-D based aerial fast-fading channel of TR 36.777 Annex B.1.1
% Alternative 1, for RMa-AV and UMa-AV links.

    % CDL-D cluster table, TR 38.901 Table 7.7.1-4.
    %            delay    P_dB    AOD     AOA     ZOD    ZOA
    lap = [      0        -13.5     0    -180     98.5   81.5
                 0.035    -18.8    89.2    89.2   85.5   86.9
                 0.612    -21      89.2    89.2   85.5   86.9
                 1.363    -22.8    89.2    89.2   85.5   86.9
                 1.405    -17.9    13     163     97.5   79.4
                 1.804    -20.1    13     163     97.5   79.4
                 2.596    -21.9    13     163     97.5   79.4
                 1.775    -22.9    34.6  -137     98.5   78.2
                 4.042    -27.8   -64.5    74.5   88.4   73.6
                 7.937    -23.6   -32.9   127.7   91.3   78.3
                 9.424    -24.8    52.6  -119.6  103.8   87
                 9.708    -30.0  -132.1    -9.1   80.3   70.6
                12.525    -27.7    77.2   -83.8   86.5   72.9 ];
    pLOS_dB   = -0.2;                     % specular power
    losRow    = [0 -180 98.5 81.5];       % model LOS angles
    cSpread   = [5 8 3 3];                % ray spreads
    xprDB     = 11;

    tauN  = lap(:,1);          % normalised delays
    pN_dB = lap(:,2);          % cluster powers
    ang   = lap(:,3:6);        % cluster angles

    % scale the K-factor to the desired value, clause 7.7.6.
    kModel_dB = pLOS_dB - 10*log10(sum(10.^(pN_dB/10)));   % eq 7.7.6-2
    pN_dB = pN_dB - (link.desiredK_dB - kModel_dB);        % eq 7.7.6-1
    % renormalise delays to DS = 1
    pAll = [10^(pLOS_dB/10); 10.^(pN_dB/10)];
    tAll = [0; tauN];
    mu   = sum(pAll .* tAll) / sum(pAll);
    ds   = sqrt(sum(pAll .* tAll.^2)/sum(pAll) - mu^2);
    tauN = tauN / ds;

    % scale the delays to the desired delay spread, clause 7.7.3.
    tau = tauN * link.desiredDS_s;                          % eq 7.7-1

    % scale the cluster angles about the LOS ray, clause 7.7.5.1.
    angScaled = ang;
    cScaled   = cSpread;
    pModelLin = 10.^(lap(:,2)/10);          % model powers
    pLOSLin   = 10^(pLOS_dB/10);
    for d = 1:4
        s = solveAngleScale(link.desiredAS(d), ...
            wrapTo180(ang(:,d) - losRow(d)), pModelLin, pLOSLin);
        % scale and translate offsets
        delta = wrapTo180(ang(:,d) - losRow(d));
        angScaled(:,d) = link.losAngles(d) + s * delta;
        cScaled(d) = cSpread(d) * s;    % ray-level scaling
    end

    % apply the Step 5 ZOD offset to the non-direct paths.
    if link.isLOS && link.zodOffsetDeg ~= 0
        switch link.offsetDim
            case 'ZoD', angScaled(:,3) = angScaled(:,3) + link.zodOffsetDeg;
            case 'ZoA', angScaled(:,4) = angScaled(:,4) + link.zodOffsetDeg;
            otherwise
                error('buildAerialCDL:badOffsetDim', ...
                    'offsetDim must be ''ZoD'' or ''ZoA''.');
        end
    end
    % mirror zenith angles back
    for zc = 3:4
        angScaled(:,zc) = mod(angScaled(:,zc), 360);
        over = angScaled(:,zc) > 180;
        angScaled(over,zc) = 360 - angScaled(over,zc);
    end

    % assemble the custom profile.
    k1_dB = pLOS_dB - pN_dB(1);   % specular over diffuse
    p1_dB = 10*log10(10^(pLOS_dB/10) + 10^(pN_dB(1)/10));

    channel = nrCDLChannel;
    channel.DelayProfile        = 'Custom';
    channel.PathDelays          = tau(:).';
    channel.AveragePathGains    = [p1_dB, pN_dB(2:end).'];
    channel.AnglesAoD           = [link.losAngles(1), angScaled(2:end,1).'];
    channel.AnglesAoA           = [link.losAngles(2), angScaled(2:end,2).'];
    channel.AnglesZoD           = [link.losAngles(3), angScaled(2:end,3).'];
    channel.AnglesZoA           = [link.losAngles(4), angScaled(2:end,4).'];
    channel.HasLOSCluster       = true;
    channel.KFactorFirstCluster = k1_dB;
    channel.AngleSpreads        = cScaled;     % ray spreads
    channel.XPR                 = xprDB;
    channel.CarrierFrequency    = link.carrierFrequency;
    channel.SampleRate          = link.sampleRate;
    channel.Seed                = link.seed;
    channel.ChannelFiltering    = false;
    channel = hArrayGeometry(channel, link.numTxAnts, link.numRxAnts, ...
        link.linkDirection);
end

% --------------------------------------------------------------------------
function s = solveAngleScale(asDesired, offsetsDeg, pClusters, pLOS)
% solves for the angle scale factor of TR 38.901 Annex A.5, by bracketing and
% bisecting the first crossing of the desired angular spread.
    pTot = pLOS + sum(pClusters);
    asOf = @(x) (180/pi) * sqrt(-2*log(abs( ...
        pLOS + sum(pClusters .* exp(1i*x*deg2rad(offsetsDeg)))) / pTot));
    % bracket the crossing
    hi = 1e-3;
    while asOf(hi) < asDesired && hi < 1e3
        hi = hi * 2;
    end
    assert(asOf(hi) >= asDesired, 'buildAerialCDL:angleScale', ...
        'Desired angular spread %.3g deg is not reachable.', asDesired);
    lo = 0;
    for it = 1:80
        mid = (lo + hi)/2;
        if asOf(mid) < asDesired, lo = mid; else, hi = mid; end
    end
    s = (lo + hi)/2;
end

% ----------------------------------------------------------------------------
function w = wrapTo180(a)
% wraps angles in degrees to (-180, 180], so the Mapping Toolbox is not needed.
    w = mod(a + 180, 360) - 180;
    w(w == -180) = 180;
end
