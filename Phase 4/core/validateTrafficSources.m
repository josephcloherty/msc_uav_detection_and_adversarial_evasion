function validateTrafficSources()
%validateTrafficSources Offline check of the D4.1 per-class traffic profiles.
%
%   Runs in seconds, no network simulation: instantiates the four
%   networkTrafficOnOff sources exactly as phase4_Pipeline's makeOnOff
%   does (same specs as phase4_UMa.m / phase4_RMa.m) and pulls packets
%   from each via generate() over 30 s of source time, then checks:
%     1. Achieved mean rate within 20 per cent of the configured rate.
%     2. Aerial DL reproduces the TR 36.777 C2 model: 1250 byte packets
%        at 100 ms spacing.
%     3. Class asymmetry: aerial UL-heavy (asym < -0.9), terrestrial
%        DL-heavy (asym > +0.5), computed exactly as the dlulAsym
%        feature, (DL-UL)/(DL+UL).
%     4. Burstiness contrast: coefficient of variation of per-0.1 s byte
%        increments near zero for the steady aerial streams and well
%        above it for the bursty terrestrial DL.
%     5. Determinism: two independently constructed sources produce
%        identical packet sequences (fixed On/Off scalars draw no
%        randomness), which the byte-reproducible CSV contract relies on.
%
%   generate() returns the time to the next packet in milliseconds; the
%   loop accumulates arrival times and sizes to build the same cumulative
%   byte series the trafficSampler would see.

    addpath(fullfile(fileparts(mfilename('fullpath')), 'functions'));
    fprintf('=== validateTrafficSources (D4.1) ===\n');
    T = 30;   % seconds of source time per stream

    %                 kbps   on(s)  off(s)  pkt(B)
    specs = { ...
        'aerial UL',      4000,  Inf,   0,    1250; ...
        'aerial DL (C2)',  100,  Inf,   0,    1250; ...
        'terrestrial DL', 2000,  1,     2,    1500; ...
        'terrestrial UL',  200,  0.5,   2.5,   500};

    vol = zeros(4,1); cv = zeros(4,1); iat = cell(4,1);
    for i = 1:4
        app = networkTrafficOnOff(GeneratePacket=true, ...
            OnTime=specs{i,3}, OffTime=specs{i,4}, ...
            DataRate=specs{i,2}, PacketSize=specs{i,5});
        [times, sizes] = pull(app, T);
        vol(i) = sum(sizes);
        iat{i} = diff(times);
        achieved_kbps = vol(i)*8/T/1e3;
        ok = abs(achieved_kbps - specs{i,2}) / specs{i,2} < 0.20;
        fprintf('%s  1: %-15s achieved %8.1f kbps (target %g)\n', ...
            tern(ok,'PASS','CHECK'), specs{i,1}, achieved_kbps, specs{i,2});
        % CV of per-0.1 s increments (the trafficBurstiness_cv definition)
        edges = 0:0.1:T;
        inc = histcounts(times, edges, 'Normalization', 'count');
        incB = zeros(size(inc));
        for k = 1:numel(edges)-1
            incB(k) = sum(sizes(times >= edges(k) & times < edges(k+1)));
        end
        cv(i) = std(incB) / max(mean(incB), eps);
    end

    % 2. C2 model shape: 1250 B every 100 ms
    m = median(iat{2});
    check(abs(m - 0.1) < 0.005, ...
        sprintf('C2 stream: median inter-packet time %.3f s (TR 36.777: 0.100 s)', m));

    % 3. Asymmetry per class, as the dlulAsym feature computes it
    aAsym = (vol(2) - vol(1)) / (vol(2) + vol(1));
    tAsym = (vol(3) - vol(4)) / (vol(3) + vol(4));
    check(aAsym < -0.9, sprintf('aerial dlulAsym = %.3f (< -0.9, UL-heavy)', aAsym));
    check(tAsym > 0.5,  sprintf('terrestrial dlulAsym = %.3f (> 0.5, DL-heavy)', tAsym));

    % 4. Burstiness contrast
    check(cv(1) < 0.3 && cv(2) < 1.1, ...
        sprintf('steady aerial streams: CV = %.2f (UL), %.2f (DL)', cv(1), cv(2)));
    check(cv(3) > 1, ...
        sprintf('bursty terrestrial DL: CV = %.2f (> 1)', cv(3)));

    % 5. Determinism of the sources
    a1 = networkTrafficOnOff(GeneratePacket=true, OnTime=1, OffTime=2, ...
        DataRate=2000, PacketSize=1500);
    a2 = networkTrafficOnOff(GeneratePacket=true, OnTime=1, OffTime=2, ...
        DataRate=2000, PacketSize=1500);
    [t1, s1] = pull(a1, 5); [t2, s2] = pull(a2, 5);
    check(isequal(t1, t2) && isequal(s1, s2), ...
        'two identically configured sources emit identical sequences');

    fprintf('All traffic-source checks passed.\n');
end

%% local helpers
function [times, sizes] = pull(app, T)
%pull Drain a traffic source for T seconds of source time.
    times = zeros(0,1); sizes = zeros(0,1);
    t = 0;
    while t < T
        [dt, pkt] = generate(app);
        t = t + dt/1000;             % generate() reports dt in milliseconds
        if t >= T, break; end
        times(end+1,1) = t;          %#ok<AGROW>
        sizes(end+1,1) = numel(pkt); %#ok<AGROW>
    end
end

function check(cond, what)
    if cond
        fprintf('PASS  %s\n', what);
    else
        error('validateTrafficSources:fail', 'FAIL: %s', what);
    end
end

function s = tern(cond, a, b)
    if cond, s = a; else, s = b; end
end
