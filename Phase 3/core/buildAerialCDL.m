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
%   Implementation notes (all clause references TR 38.901, verified in the
%   38901-j40 source document):
%     - The built-in DelayProfile='CDL-D' does not expose per-cluster ZOD,
%       which Step 5 of Annex B.1.1 needs, so the CDL-D cluster table
%       (Table 7.7.1-4, hard-coded below exactly as published) is supplied
%       through DelayProfile='Custom' and the three scalings are applied
%       numerically here:
%         K-factor scaling  per clause 7.7.6 (eq 7.7.6-1/-2, then delay
%                           re-normalisation to DS = 1),
%         delay scaling     per clause 7.7.3 (eq 7.7-1),
%         angle scaling     per clause 7.7.5.1 using the LOS-preserving
%                           variant (eq 7.7-6), which is the appropriate
%                           form here because Annex B.1.1 Step 3 sets the
%                           desired mean angles to the actual LOS angles.
%       The scale factor is solved numerically per Annex A.5 (eq A-5/A-6,
%       circular spread of the LOS ray plus clusters at model powers);
%       this reproduces the published Table 7.7.5.1-1 factors exactly.
%       The per-cluster ray spreads are scaled by the same factor so that
%       the scaling acts on ray angles as required by Step 3.
%     - Step 5 ZOD offset: nrCDLChannel custom profiles let the first
%       (LOS) cluster's specular and diffuse parts share one angle set, so
%       the offset is applied to clusters 2..13 only. The diffuse part of
%       cluster 1 sits 13.3 dB below the specular ray in CDL-D, so the
%       error from leaving it un-offset is small. Recorded in the
%       deviations log.

    % ---- CDL-D, TR 38.901 Table 7.7.1-4 (verified against source) -------
    % Cluster 1 is Specular(LOS) -0.2 dB plus a Laplacian part -13.5 dB at
    % the same delay and angles. Rows below are the Laplacian clusters.
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

    % ---- Clause 7.7.6: K-factor scaling ---------------------------------
    kModel_dB = pLOS_dB - 10*log10(sum(10.^(pN_dB/10)));   % eq 7.7.6-2
    pN_dB = pN_dB - (link.desiredK_dB - kModel_dB);        % eq 7.7.6-1
    % Delay re-normalisation to DS = 1 (clause 7.7.6, steps 1-2). The rms
    % delay spread is computed over the specular ray plus all clusters.
    pAll = [10^(pLOS_dB/10); 10.^(pN_dB/10)];
    tAll = [0; tauN];
    mu   = sum(pAll .* tAll) / sum(pAll);
    ds   = sqrt(sum(pAll .* tAll.^2)/sum(pAll) - mu^2);
    tauN = tauN / ds;

    % ---- Clause 7.7.3: delay scaling to the desired delay spread --------
    tau = tauN * link.desiredDS_s;                          % eq 7.7-1

    % ---- Clause 7.7.5.1 (eq 7.7-6, LOS-preserving): angle scaling -------
    % The scale factor s is computed per TR 38.901 Annex A.5 (eq A-5/A-6):
    % the smallest x >= 0 at which the circular angular spread of the CDL
    % (LOS ray plus clusters, model powers, offsets multiplied by x)
    % equals the desired spread. This numerical solve reproduces the
    % published Table 7.7.5.1-1 factors exactly (checked for all tabulated
    % CDL-D entries), unlike a simple linear spread ratio.
    angScaled = ang;
    cScaled   = cSpread;
    pModelLin = 10.^(lap(:,2)/10);          % original CDL-D cluster powers
    pLOSLin   = 10^(pLOS_dB/10);
    for d = 1:4
        s = solveAngleScale(link.desiredAS(d), ...
            wrapTo180(ang(:,d) - losRow(d)), pModelLin, pLOSLin);
        % eq 7.7-6: scale cluster offsets about the model LOS ray and
        % translate to the desired (geometric) LOS direction.
        delta = wrapTo180(ang(:,d) - losRow(d));
        angScaled(:,d) = link.losAngles(d) + s * delta;
        cScaled(d) = cSpread(d) * s;    % ray-level scaling, Step 3 note
    end

    % ---- Annex B.1.1 Step 5/6: ZOD offset on non-direct paths -----------
    if link.isLOS && link.zodOffsetDeg ~= 0
        switch link.offsetDim
            case 'ZoD', angScaled(:,3) = angScaled(:,3) + link.zodOffsetDeg;
            case 'ZoA', angScaled(:,4) = angScaled(:,4) + link.zodOffsetDeg;
            otherwise
                error('buildAerialCDL:badOffsetDim', ...
                    'offsetDim must be ''ZoD'' or ''ZoA''.');
        end
    end
    % Mirror zenith angles back into [0, 180] (TR 38.901 convention).
    for zc = 3:4
        angScaled(:,zc) = mod(angScaled(:,zc), 360);
        over = angScaled(:,zc) > 180;
        angScaled(over,zc) = 360 - angScaled(over,zc);
    end

    % ---- Assemble the custom profile ------------------------------------
    % First path carries the specular ray plus the first Laplacian cluster
    % (HasLOSCluster splits them by KFactorFirstCluster). Its angles are
    % the geometric LOS angles.
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
%solveAngleScale Scale factor per TR 38.901 Annex A.5 (eq A-5/A-6).
%   Finds the smallest x >= 0 such that AS(x) = asDesired, where AS(x) is
%   the circular angular spread of the LOS ray (offset 0, power pLOS) and
%   the clusters (offsets scaled by x, powers pClusters):
%     AS(x) = (180/pi)*sqrt(-2*ln(|pLOS + sum(pN*exp(j*x*offset))| / sumP))
%   AS(0) = 0 and AS increases from x = 0, so the first crossing is found
%   by bracketing and bisection. Deterministic, no toolbox dependencies.
    pTot = pLOS + sum(pClusters);
    asOf = @(x) (180/pi) * sqrt(-2*log(abs( ...
        pLOS + sum(pClusters .* exp(1i*x*deg2rad(offsetsDeg)))) / pTot));
    % Bracket the first crossing
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
%wrapTo180 Wrap angles in degrees to (-180, 180]. Local shadow of the
% Mapping Toolbox function so that toolbox is not a dependency.
    w = mod(a + 180, 360) - 180;
    w(w == -180) = 180;
end
