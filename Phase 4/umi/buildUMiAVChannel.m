function channel = buildUMiAVChannel(link, cfg)
%buildUMiAVChannel TR 36.777 UMi-AV Alternative 1 fast fading ("reverse UMa").
%
%   CHANNEL = buildUMiAVChannel(LINK, CFG) returns an nrCDLChannel for an
%   aerial-band UMi-AV link. Per TR 36.777 Annex B.1.1 (final paragraph),
%   UMi-AV Alternative 1 is NOT CDL-D based: "the fast fading model in
%   Section 7.5 of [4] is reused with the angular spreads at the base
%   station and UE interchanged" (the base station sits below the average
%   rooftop while the aerial UE is well above it, hence "reverse UMa").
%   This corrects the earlier project documentation, which wrongly assumed
%   a CDL-D approach for UMi-AV; see the deviations log.
%
%   Implementation: single-link TR 38.901 clause 7.5 cluster generation
%   (steps 4-8) with UMi - Street Canyon parameters (Table 7.5-6 Part-1
%   and Table 7.5-8 of the provided 38901-j40 source document, values
%   verified there), then the BS<->UE angular-spread interchange:
%   ASD<->ASA and ZSD<->ZSA, applied to both the drawn large-scale spreads
%   and the cluster-wise ray spreads. All other UMi parameters (delay
%   distribution, cluster powers, per-cluster shadowing, number of
%   clusters, XPR, ZOD offset) are reused unchanged, which is the literal
%   reading of the TR sentence.
%
%   Deliberate simplifications, recorded in the deviations log:
%     - Large-scale parameters are drawn INDEPENDENTLY (the Table 7.5-6
%       cross-correlation matrix and spatial autocorrelation are not
%       applied); this is a single-link model, not a system-level drop.
%     - nrCDLChannel takes one scalar XPR, so the per-ray lognormal XPR of
%       step 9 is replaced by the mu_XPR value.
%     - LOS/NLOS state and geometry are fixed at setup (static CDL,
%       matching the rest of the Phase 3 pipeline).
%
%   All randomness comes from a Threefry stream seeded with LINK.seed, so
%   a fixed scenario seed regenerates the channel exactly.
%
%   LINK fields: isLOS, d2D, d3D, hBS, hUT, losAngles [AoD AoA ZoD ZoA]
%   (transmitter convention of the object being built), seed, sampleRate,
%   carrierFrequency, numTxAnts, numRxAnts, linkDirection.

    rs = RandStream('Threefry', 'Seed', link.seed);
    fcGHz = max(link.carrierFrequency/1e9, 2);   % Table 7.5-6 Note 7
    lg1f = log10(1 + fcGHz);

    % ---- Table 7.5-6 Part-1, UMi - Street Canyon (verified values) ------
    if link.isLOS
        muDS  = -0.18*lg1f - 7.28;   sdDS  = 0.39;
        muASD = -0.05*lg1f + 1.21;   sdASD = 0.08*lg1f + 0.29;
        muASA = -0.07*lg1f + 1.66;   sdASA = 0.021*lg1f + 0.26;
        muZSA = -0.11*lg1f + 0.81;   sdZSA = -0.03*lg1f + 0.29;
        muK = 9; sdK = 5;
        rTau = 3;  N = 12;  M = 20;
        cASD = 3;  cASA = 17;  cZSA = 7;   % cluster-wise spreads (deg)
        zeta = 3;  xprDB = 9;
    else
        muDS  = -0.22*lg1f - 6.87;   sdDS  = 0.19*lg1f + 0.22;
        muASD = -0.24*lg1f + 1.54;   sdASD = 0.10*lg1f + 0.33;
        muASA = -0.07*lg1f + 1.76;   sdASA = 0.05*lg1f + 0.27;
        muZSA = -0.03*lg1f + 0.92;   sdZSA = -0.05*lg1f + 0.35;
        muK = NaN; sdK = NaN;
        rTau = 2.1;  N = 19;  M = 20;
        cASD = 10;  cASA = 22;  cZSA = 7;
        zeta = 3;  xprDB = 8;
    end

    % ---- Table 7.5-8: UMi ZSD and ZOD offset (verified values) ----------
    d2Dkm = link.d2D / 1000;
    if link.isLOS
        muZSD = max(-0.21, -14.8*d2Dkm + 0.01*abs(link.hUT - link.hBS) + 0.83);
        muOffZOD = 0;
    else
        muZSD = max(-0.5, -3.1*d2Dkm + 0.01*max(link.hUT - link.hBS, 0) + 0.2);
        muOffZOD = -10^(-1.5*log10(max(10, link.d2D)) + 3.3);
    end
    sdZSD = 0.35;

    % ---- Step 4: draw LSPs (independent lognormals; see header) ---------
    DS  = 10^(muDS  + sdDS  * randn(rs));            % seconds
    ASD = min(10^(muASD + sdASD * randn(rs)), 104);  % clause 7.5 caps
    ASA = min(10^(muASA + sdASA * randn(rs)), 104);
    ZSD = min(10^(muZSD + sdZSD * randn(rs)), 52);
    ZSA = min(10^(muZSA + sdZSA * randn(rs)), 52);
    if link.isLOS
        K = muK + sdK * randn(rs);                   % dB
    else
        K = NaN;
    end

    % ---- TR 36.777 interchange: BS-side <-> UE-side angular spreads -----
    [ASD, ASA] = deal(ASA, ASD);
    [ZSD, ZSA] = deal(ZSA, ZSD);
    % Cluster-wise ray spreads follow their large-scale counterparts.
    % Standard UMi uses cZSD = (3/8)*10^muZSD (eq 7.5-20); after the
    % interchange that value belongs to the arrival side.
    cZSD_used = cZSA;                    % was the UE-side value
    cZSA_used = (3/8) * 10^muZSD;        % was the BS-side value
    [cASD, cASA] = deal(cASA, cASD);

    % ---- Step 5: cluster delays (eq 7.5-1/-2, LOS: eq 7.5-3/-4) ---------
    tauP = -rTau * DS * log(rand(rs, N, 1));
    tau  = sort(tauP - min(tauP));
    if link.isLOS
        Ctau = 0.7705 - 0.0433*K + 0.0002*K^2 + 0.000017*K^3;  % eq 7.5-3
        tauFinal = tau / Ctau;                                  % eq 7.5-4
    else
        tauFinal = tau;
    end

    % ---- Step 6: cluster powers (eq 7.5-5/-6, LOS: 7.5-7/-8) ------------
    Zn = zeta * randn(rs, N, 1);
    P  = exp(-tau * (rTau - 1) / (rTau * DS)) .* 10.^(-Zn/10);
    P  = P / sum(P);                       % eq 7.5-6 powers (for -25 dB cut)
    if link.isLOS
        KR = 10^(K/10);
        Pn = P / (KR + 1);                 % eq 7.5-8 diffuse powers
        P1LOS = KR / (KR + 1);             % eq 7.5-7 specular power
    else
        Pn = P;
        P1LOS = 0;
    end

    % Remove clusters more than 25 dB below the strongest (clause 7.5).
    keep = 10*log10(P) >= (10*log10(max(P)) - 25);
    keep(1) = true;                        % never drop the first cluster
    tauFinal = tauFinal(keep);  Pn = Pn(keep);  P = P(keep);
    Nk = nnz(keep);

    % ---- Step 7: cluster angles ------------------------------------------
    % Scaling factors, Tables 7.5-2 / 7.5-4 (verified). Values for the two
    % UMi cluster counts used here; interpolation covers dropped clusters.
    cphiTab = [4 0.779; 5 0.860; 6 0.921; 7 0.973; 8 1.018; 10 1.090; ...
               11 1.123; 12 1.146; 14 1.190; 15 1.211; 16 1.226; ...
               19 1.273; 20 1.289; 25 1.358];
    cthTab  = [6 0.788; 7 0.847; 8 0.889; 10 0.957; 11 1.031; 12 1.104; ...
               14 1.1072; 15 1.1088; 16 1.1276; 19 1.184; 20 1.178; 25 1.282];
    Cphi = interp1(cphiTab(:,1), cphiTab(:,2), min(max(Nk, 4), 25));
    Cth  = interp1(cthTab(:,1),  cthTab(:,2),  min(max(Nk, 6), 25));
    if link.isLOS   % K-dependent correction (verified polynomials)
        Cphi = Cphi * (1.1035 - 0.028*K - 0.002*K^2 + 0.0001*K^3);
        Cth  = Cth  * (1.3086 + 0.0339*K - 0.0077*K^2 + 0.0002*K^3);
    end

    % Powers used for angle generation: eq 7.5-8 set in LOS (with the
    % specular power on cluster 1), eq 7.5-6 set in NLOS.
    Pang = Pn;
    if link.isLOS, Pang(1) = Pang(1) + P1LOS; end

    losAoD = link.losAngles(1); losAoA = link.losAngles(2);
    losZoD = link.losAngles(3); losZoA = link.losAngles(4);

    aoa = azimuthAngles(rs, Pang, ASA, Cphi, losAoA, link.isLOS);  % eq 7.5-9..-12
    aod = azimuthAngles(rs, Pang, ASD, Cphi, losAoD, link.isLOS);
    zoa = zenithAngles(rs, Pang, ZSA, Cth, losZoA, 0,        link.isLOS); % eq 7.5-14..-16
    zod = zenithAngles(rs, Pang, ZSD, Cth, losZoD, muOffZOD, link.isLOS); % eq 7.5-19

    % ---- Assemble the nrCDLChannel custom profile ------------------------
    if link.isLOS
        p1  = Pn(1) + P1LOS;
        k1  = 10*log10(P1LOS / Pn(1));
        gains = [10*log10(p1); 10*log10(Pn(2:end))];
    else
        k1 = -Inf; %#ok<NASGU>  (no LOS cluster)
        gains = 10*log10(Pn);
    end

    channel = nrCDLChannel;
    channel.DelayProfile     = 'Custom';
    channel.PathDelays       = tauFinal(:).';
    channel.AveragePathGains = gains(:).';
    channel.AnglesAoD        = aod(:).';
    channel.AnglesAoA        = aoa(:).';
    channel.AnglesZoD        = zod(:).';
    channel.AnglesZoA        = zoa(:).';
    if link.isLOS
        channel.HasLOSCluster       = true;
        channel.KFactorFirstCluster = k1;
    end
    channel.AngleSpreads     = [cASD cASA cZSD_used cZSA_used];
    channel.XPR              = xprDB;
    channel.CarrierFrequency = link.carrierFrequency;
    channel.SampleRate       = link.sampleRate;
    channel.Seed             = link.seed;
    channel.ChannelFiltering = false;
    channel = hArrayGeometry(channel, link.numTxAnts, link.numRxAnts, ...
        link.linkDirection);
end

% ----------------------------------------------------------------------------
function phi = azimuthAngles(rs, P, AS, Cphi, losAngle, isLOS)
%azimuthAngles Clause 7.5 step 7 azimuth generation (eq 7.5-9 to 7.5-12).
    phiP = 2 * (AS/1.4) * sqrt(-log(P / max(P))) / Cphi;   % eq 7.5-9
    Xn = 2*(rand(rs, numel(P), 1) > 0.5) - 1;
    Yn = (AS/7) * randn(rs, numel(P), 1);
    if isLOS   % eq 7.5-12: enforce first cluster on the LOS direction
        phi = (Xn.*phiP + Yn) - (Xn(1)*phiP(1) + Yn(1) - losAngle);
    else       % eq 7.5-11
        phi = Xn.*phiP + Yn + losAngle;
    end
    phi = wrapTo180(phi);
end

function th = zenithAngles(rs, P, ZS, Cth, losAngle, muOff, isLOS)
%zenithAngles Clause 7.5 step 7 zenith generation (eq 7.5-14 to 7.5-16,
% and eq 7.5-19 for ZOD where muOff is the NLOS ZOD offset).
    thP = -ZS * log(P / max(P)) / Cth;                     % eq 7.5-14
    Xn = 2*(rand(rs, numel(P), 1) > 0.5) - 1;
    Yn = (ZS/7) * randn(rs, numel(P), 1);
    if isLOS   % enforce first cluster on the LOS direction
        th = (Xn.*thP + Yn) - (Xn(1)*thP(1) + Yn(1) - losAngle);
    else
        th = Xn.*thP + Yn + losAngle + muOff;
    end
    % Mirror into [0, 180] (clause 7.5 wrapping convention)
    th = mod(th, 360);
    over = th > 180;
    th(over) = 360 - th(over);
end

% ----------------------------------------------------------------------------
function w = wrapTo180(a)
%wrapTo180 Wrap angles in degrees to (-180, 180]. Local shadow of the
% Mapping Toolbox function so that toolbox is not a dependency.
    w = mod(a + 180, 360) - 180;
    w(w == -180) = 180;
end
