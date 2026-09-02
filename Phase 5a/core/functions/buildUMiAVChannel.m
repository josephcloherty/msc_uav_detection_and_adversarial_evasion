function channel = buildUMiAVChannel(link, cfg)
% builds the UMi-AV Alternative 1 fast-fading channel: TR 38.901 clause 7.5 UMi
% cluster generation with the base station and UE angular spreads interchanged.

    rs = RandStream('Threefry', 'Seed', link.seed);
    fcGHz = max(link.carrierFrequency/1e9, 2);   % Table 7.5-6
    lg1f = log10(1 + fcGHz);

    % UMi street-canyon parameters, Table 7.5-6 Part-1.
    if link.isLOS
        muDS  = -0.18*lg1f - 7.28;   sdDS  = 0.39;
        muASD = -0.05*lg1f + 1.21;   sdASD = 0.08*lg1f + 0.29;
        muASA = -0.07*lg1f + 1.66;   sdASA = 0.021*lg1f + 0.26;
        muZSA = -0.11*lg1f + 0.81;   sdZSA = -0.03*lg1f + 0.29;
        muK = 9; sdK = 5;
        rTau = 3;  N = 12;  M = 20;
        cASD = 3;  cASA = 17;  cZSA = 7;   % cluster spreads
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

    % UMi ZSD and ZOD offset, Table 7.5-8.
    d2Dkm = link.d2D / 1000;
    if link.isLOS
        muZSD = max(-0.21, -14.8*d2Dkm + 0.01*abs(link.hUT - link.hBS) + 0.83);
        muOffZOD = 0;
    else
        muZSD = max(-0.5, -3.1*d2Dkm + 0.01*max(link.hUT - link.hBS, 0) + 0.2);
        muOffZOD = -10^(-1.5*log10(max(10, link.d2D)) + 3.3);
    end
    sdZSD = 0.35;

    % draw the large-scale parameters, independently.
    DS  = 10^(muDS  + sdDS  * randn(rs));            % seconds
    ASD = min(10^(muASD + sdASD * randn(rs)), 104);  % clause 7.5 cap
    ASA = min(10^(muASA + sdASA * randn(rs)), 104);
    ZSD = min(10^(muZSD + sdZSD * randn(rs)), 52);
    ZSA = min(10^(muZSA + sdZSA * randn(rs)), 52);
    if link.isLOS
        K = muK + sdK * randn(rs);                   % dB
    else
        K = NaN;
    end

    % interchange the base station and UE angular spreads.
    [ASD, ASA] = deal(ASA, ASD);
    [ZSD, ZSA] = deal(ZSA, ZSD);
    % ray spreads follow their large-scale counterparts
    cZSD_used = cZSA;                    % was UE-side
    cZSA_used = (3/8) * 10^muZSD;        % was BS-side
    [cASD, cASA] = deal(cASA, cASD);

    % draw the cluster delays, eq 7.5-1 to 7.5-4.
    tauP = -rTau * DS * log(rand(rs, N, 1));
    tau  = sort(tauP - min(tauP));
    if link.isLOS
        Ctau = 0.7705 - 0.0433*K + 0.0002*K^2 + 0.000017*K^3;  % eq 7.5-3
        tauFinal = tau / Ctau;                                  % eq 7.5-4
    else
        tauFinal = tau;
    end

    % draw the cluster powers, eq 7.5-5 to 7.5-8.
    Zn = zeta * randn(rs, N, 1);
    P  = exp(-tau * (rTau - 1) / (rTau * DS)) .* 10.^(-Zn/10);
    P  = P / sum(P);                       % eq 7.5-6
    if link.isLOS
        KR = 10^(K/10);
        Pn = P / (KR + 1);                 % diffuse powers
        P1LOS = KR / (KR + 1);             % specular power
    else
        Pn = P;
        P1LOS = 0;
    end

    % drop clusters 25 dB down
    keep = 10*log10(P) >= (10*log10(max(P)) - 25);
    keep(1) = true;                        % keep the first
    tauFinal = tauFinal(keep);  Pn = Pn(keep);  P = P(keep);
    Nk = nnz(keep);

    % draw the cluster angles.
    cphiTab = [4 0.779; 5 0.860; 6 0.921; 7 0.973; 8 1.018; 10 1.090; ...
               11 1.123; 12 1.146; 14 1.190; 15 1.211; 16 1.226; ...
               19 1.273; 20 1.289; 25 1.358];
    cthTab  = [6 0.788; 7 0.847; 8 0.889; 10 0.957; 11 1.031; 12 1.104; ...
               14 1.1072; 15 1.1088; 16 1.1276; 19 1.184; 20 1.178; 25 1.282];
    Cphi = interp1(cphiTab(:,1), cphiTab(:,2), min(max(Nk, 4), 25));
    Cth  = interp1(cthTab(:,1),  cthTab(:,2),  min(max(Nk, 6), 25));
    if link.isLOS   % K-dependent correction
        Cphi = Cphi * (1.1035 - 0.028*K - 0.002*K^2 + 0.0001*K^3);
        Cth  = Cth  * (1.3086 + 0.0339*K - 0.0077*K^2 + 0.0002*K^3);
    end

    % powers used for angle generation
    Pang = Pn;
    if link.isLOS, Pang(1) = Pang(1) + P1LOS; end

    losAoD = link.losAngles(1); losAoA = link.losAngles(2);
    losZoD = link.losAngles(3); losZoA = link.losAngles(4);

    aoa = azimuthAngles(rs, Pang, ASA, Cphi, losAoA, link.isLOS);  % eq 7.5-9..-12
    aod = azimuthAngles(rs, Pang, ASD, Cphi, losAoD, link.isLOS);
    zoa = zenithAngles(rs, Pang, ZSA, Cth, losZoA, 0,        link.isLOS); % eq 7.5-14..-16
    zod = zenithAngles(rs, Pang, ZSD, Cth, losZoD, muOffZOD, link.isLOS); % eq 7.5-19

    % assemble the custom profile.
    if link.isLOS
        p1  = Pn(1) + P1LOS;
        k1  = 10*log10(P1LOS / Pn(1));
        gains = [10*log10(p1); 10*log10(Pn(2:end))];
    else
        k1 = -Inf; %#ok<NASGU>  % no LOS cluster
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
% generates the clause 7.5 step 7 azimuth angles, eq 7.5-9 to 7.5-12.
    phiP = 2 * (AS/1.4) * sqrt(-log(P / max(P))) / Cphi;   % eq 7.5-9
    Xn = 2*(rand(rs, numel(P), 1) > 0.5) - 1;
    Yn = (AS/7) * randn(rs, numel(P), 1);
    if isLOS   % eq 7.5-12
        phi = (Xn.*phiP + Yn) - (Xn(1)*phiP(1) + Yn(1) - losAngle);
    else       % eq 7.5-11
        phi = Xn.*phiP + Yn + losAngle;
    end
    phi = wrapTo180(phi);
end

function th = zenithAngles(rs, P, ZS, Cth, losAngle, muOff, isLOS)
% generates the clause 7.5 step 7 zenith angles, eq 7.5-14 to 7.5-16 and
% eq 7.5-19 for the ZOD offset.
    thP = -ZS * log(P / max(P)) / Cth;                     % eq 7.5-14
    Xn = 2*(rand(rs, numel(P), 1) > 0.5) - 1;
    Yn = (ZS/7) * randn(rs, numel(P), 1);
    if isLOS   % pin the first cluster
        th = (Xn.*thP + Yn) - (Xn(1)*thP(1) + Yn(1) - losAngle);
    else
        th = Xn.*thP + Yn + losAngle + muOff;
    end
    % mirror into [0, 180]
    th = mod(th, 360);
    over = th > 180;
    th(over) = 360 - th(over);
end

% ----------------------------------------------------------------------------
function w = wrapTo180(a)
% wraps angles in degrees to (-180, 180], so the Mapping Toolbox is not needed.
    w = mod(a + 180, 360) - 180;
    w(w == -180) = 180;
end
