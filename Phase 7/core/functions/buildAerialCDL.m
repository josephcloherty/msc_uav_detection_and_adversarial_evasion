function channel = buildAerialCDL(link)
%buildAerialCDL TR 36.777 Annex B.1.1 Alternative 1 aerial fast-fading channel.
%
%   CHANNEL = buildAerialCDL(LINK) returns an nrCDLChannel implementing the
%   CDL-D based aerial fast-fading model of TR 36.777 Annex B.1.1
%   (Alternative 1) for RMa-AV and UMa-AV. LINK is a struct:
%
%       .isLOS         logical, LOS state of the link (from Table B-1 draw)
%       .desiredAS     [ASD ASA ZSD ZSA] in degrees, at the TRANSMIT side
%                      first (Table B.1.1-1 RMa-AV / B.1.1-2 UMa-AV values,
%                      mirrored by the caller for uplink objects)
%       .desiredK_dB   desired K-factor (20 LOS / 10 NLOS)
%       .desiredDS_s   desired delay spread in seconds (10e-9 / 30e-9)
%       .losAngles     [AoD AoA ZoD ZoA] in degrees, the geometric LOS
%                      direction of the link (transmitter convention of
%                      the channel object being built)
%       .zodOffsetDeg  Annex B.1.1 Step 5 offset (0 in NLOS). Applied to
%                      the base-station-side zenith angle of the
%                      non-direct clusters only.
%       .offsetDim     'ZoD' when the BS is the transmitter (downlink
%                      object) or 'ZoA' when the BS is the receiver
%                      (uplink object)
%       .sampleRate, .carrierFrequency, .seed
%       .numTxAnts, .numRxAnts, .linkDirection ('uplink'|'downlink')
%
%   Implementation notes, clause references to TR 38.901 (38901-j40).
%
%   The built-in DelayProfile='CDL-D' does not expose per-cluster ZOD, which
%   Step 5 needs, so the cluster table is supplied through
%   DelayProfile='Custom' and the three scalings are applied here:
%     K-factor  clause 7.7.6, then delay re-normalisation to DS = 1
%     delay     clause 7.7.3
%     angle     clause 7.7.5.1, LOS-preserving variant, which is the right
%               form because Step 3 sets the desired mean angles to the
%               actual LOS angles
%
%   The angle scale factor is solved numerically per Annex A.5, which
%   reproduces the published Table 7.7.5.1-1 factors exactly, and the ray
%   spreads take the same factor as Step 3 requires.
%
%   The Step 5 ZOD offset goes on clusters 2..13 only, because a custom
%   profile makes the first cluster's specular and diffuse parts share one
%   angle set. Cluster 1's diffuse part is 13.3 dB down, so the error is
%   small; recorded in the deviations log.

    % CDL-D, TR 38.901 Table 7.7.1-4.
    % Cluster 1 is specular LOS at -0.2 dB plus a Laplacian part at -13.5 dB
    % on the same delay and angles, and the rows below are the Laplacians.
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
    pLOS_dB   = -0.2;                     % specular ray power
    losRow    = [0 -180 98.5 81.5];       % model LOS ray angles
    cSpread   = [5 8 3 3];                % [cASD cASA cZSD cZSA], Table 7.7.1-4
    xprDB     = 11;

    tauN  = lap(:,1);          % normalized delays
    pN_dB = lap(:,2);          % Laplacian cluster powers (dB)
    ang   = lap(:,3:6);        % [AOD AOA ZOD ZOA] per cluster

    % Clause 7.7.6, K-factor scaling.
    kModel_dB = pLOS_dB - 10*log10(sum(10.^(pN_dB/10)));   % eq 7.7.6-2
    pN_dB = pN_dB - (link.desiredK_dB - kModel_dB);        % eq 7.7.6-1
    % Delay re-normalisation to DS = 1, over the specular ray and all
    % clusters together.
    pAll = [10^(pLOS_dB/10); 10.^(pN_dB/10)];
    tAll = [0; tauN];
    mu   = sum(pAll .* tAll) / sum(pAll);
    ds   = sqrt(sum(pAll .* tAll.^2)/sum(pAll) - mu^2);
    tauN = tauN / ds;

    % Clause 7.7.3, delay scaling to the desired delay spread.
    tau = tauN * link.desiredDS_s;                          % eq 7.7-1

    % Clause 7.7.5.1, LOS-preserving angle scaling.
    % The factor is the smallest x >= 0 at which the circular angular spread
    % equals the desired one, solved per Annex A.5 because a simple linear
    % spread ratio does not reproduce the published factors.
    angScaled = ang;
    cScaled   = cSpread;
    pModelLin = 10.^(lap(:,2)/10);          % original CDL-D cluster powers
    pLOSLin   = 10^(pLOS_dB/10);
    for d = 1:4
        s = solveAngleScale(link.desiredAS(d), ...
            wrapTo180(ang(:,d) - losRow(d)), pModelLin, pLOSLin);
        % Scale the cluster offsets about the model LOS ray, then translate
        % to the geometric LOS direction.
        delta = wrapTo180(ang(:,d) - losRow(d));
        angScaled(:,d) = link.losAngles(d) + s * delta;
        cScaled(d) = cSpread(d) * s;    % ray-level scaling, Step 3 note
    end

    % Annex B.1.1 Step 5/6, ZOD offset on the non-direct paths.
    if link.isLOS && link.zodOffsetDeg ~= 0
        switch link.offsetDim
            case 'ZoD', angScaled(:,3) = angScaled(:,3) + link.zodOffsetDeg;
            case 'ZoA', angScaled(:,4) = angScaled(:,4) + link.zodOffsetDeg;
            otherwise
                error('buildAerialCDL:badOffsetDim', ...
                    'offsetDim must be ''ZoD'' or ''ZoA''.');
        end
    end
    % Mirror zenith angles back into [0, 180].
    for zc = 3:4
        angScaled(:,zc) = mod(angScaled(:,zc), 360);
        over = angScaled(:,zc) > 180;
        angScaled(over,zc) = 360 - angScaled(over,zc);
    end

    % Assemble the custom profile.
    % The first path carries the specular ray plus the first Laplacian
    % cluster, split by KFactorFirstCluster, at the geometric LOS angles.
    k1_dB = pLOS_dB - pN_dB(1);   % specular over (scaled) diffuse, cluster 1
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
    channel.AngleSpreads        = cScaled;     % per-cluster ray spreads
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
%solveAngleScale Scale factor per TR 38.901 Annex A.5.
%   Finds the smallest x >= 0 with AS(x) = asDesired, where
%     AS(x) = (180/pi)*sqrt(-2*ln(|pLOS + sum(pN*exp(j*x*offset))| / sumP))
%   AS(0) = 0 and rises from there, so bracketing and bisection find the
%   first crossing without any toolbox dependency.
    pTot = pLOS + sum(pClusters);
    asOf = @(x) (180/pi) * sqrt(-2*log(abs( ...
        pLOS + sum(pClusters .* exp(1i*x*deg2rad(offsetsDeg)))) / pTot));
    % Bracket the first crossing.
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
%wrapTo180 Wrap angles in degrees to (-180, 180].
% Local copy so the Mapping Toolbox is not a dependency.
    w = mod(a + 180, 360) - 180;
    w(w == -180) = 180;
end
