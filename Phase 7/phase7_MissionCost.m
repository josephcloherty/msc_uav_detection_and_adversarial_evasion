function [C, R] = phase7_MissionCost(condition, seed, varargin)
%phase7_MissionCost Mission cost of each evasion condition, per scenario and seed.
%
%   Produces the cost axis of the detectability-versus-mission-cost frontier.
%   Detectability comes from Phase 6 and Phase 8; this function supplies the
%   cost, one row per (condition, scenario, seed), ready to join on those keys.
%
%   USAGE
%     C = phase7_MissionCost()                        % every condition, every seed
%     C = phase7_MissionCost('lowAltitude')           % one condition, all seeds
%     C = phase7_MissionCost('combined', 46)          % one condition, one seed
%     C = phase7_MissionCost('all', 46:50)            % seed subset
%     [C,R] = phase7_MissionCost(...)                 % R = raw per-run metrics
%
%   OPTIONS
%     'Profile'   'surveillance' | 'c2_nav' | 'delivery' | 'all'  (default 'all')
%     'DataDir'   override the data folder
%     'Export'    write results/phase7_missioncost_*.csv           (default true)
%     'Verbose'   console report                                   (default true)
%
%   COST MODEL
%     Five terms, each an evasive-versus-honest difference paired on the same
%     seed and scenario:
%
%       dT  payload deficit      lost uplink payload throughput
%       dR  link degradation     realised outage plus SINR margin erosion
%       dL  responsiveness       handover interruption plus traffic gating
%       dV  link volatility      growth in within-window serving SINR variance
%       dK  mission duration     time penalty from reduced cruise speed
%
%     C_op = w.[dT dR dL dV dK] under a declared mission profile, or the
%     Chebyshev max if compensation between terms is not acceptable.
%
%     The cost of flying low is expressed through dR, not through any sensor
%     or payload-geometry term. The simulator models the radio link, so the
%     measurable consequence of descending is an altered link: changed serving
%     SINR, changed interference from the visible-gNB set, and changed
%     handover behaviour. A sensor-footprint term would import a mission
%     assumption the simulation cannot test.
%
%     Terms are SIGNED by default (A.allowNegative). An evasion that improves
%     the link carries negative cost rather than zero. This matters: at
%     altitude the aerial UE has line of sight to many gNBs and suffers heavy
%     inter-cell interference, so descending sometimes raises serving SINR.
%     Measured over the 15 lowAltitude runs, mean serving SINR changes by
%     -6.8 dB on average but ranges from +10.2 dB to -14.9 dB, improving in
%     2 of 15 seeds. Clamping at zero would hide the fact that low-altitude
%     evasion is occasionally free in link terms.
%
%     Adversary capability tier is reported but NEVER summed into C_op. It is
%     ordinal, fixed per condition, and does not vary across seeds.
%
%   DATA EXPECTED
%     data/honest/features_<scenario>_seed<NN>.csv
%     data/evasive/<condition>/features_<scenario>_seed<NN>.csv
%
%   NOTE ON WINDOW COUNTS
%     The honest hold-out was generated at the Phase 5 run length (50 windows
%     per UE-run); the Phase 7 evasive runs are 30. The honest comparator is
%     truncated to the evasive window count before any metric is formed, as
%     phase7_Config records is required. Comparing 50 honest windows against
%     30 evasive ones silently compares different mission spans.
%
%   Requires MATLAB R2024b. Part of the uav_detect Phase 7 pipeline.
%   See also phase7_Config, phase7_RunBatch, phase7_CostModel.

% =========================================================================
% ============================  ADJUSTERS  ================================
% ==============  everything tunable lives in this block  =================
% =========================================================================

A = struct();

% ---- Payload term, dT ---------------------------------------------------
% The aerial traffic spec in phase7_Config is UL 4000 kbps continuous (sensor
% or video return) against DL 100 kbps (command link), so payload cost is an
% uplink quantity. Reshaping raises DL because it adopts the terrestrial
% profile; that is a changed traffic pattern, not a mission benefit, so DL is
% excluded by default.
A.payloadColumn     = 'ulThr_bps';        % 'ulThr_bps' | 'thr_mean_bps' | 'dlThr_bps'

% ---- Link degradation term, dR ------------------------------------------
% Two parts, because they measure different failures and are close to
% uncorrelated in this dataset (r = +0.03 across all 45 runs):
%
%   outage  realised loss of link, the fraction of windows whose worst SINR
%           falls below the demodulation floor. Measured aerial rates at
%           0 dB: honest 8.8%, lowAltitude 22.4%.
%   margin  erosion of headroom that has not yet become failure. The 20 MHz
%           abstracted PHY leaves enough margin that a large SINR loss often
%           produces no outage and no throughput loss, so outage alone
%           understates the cost of descending.
%
% servSINR_mean_dB sits at 17-25 dB across every condition and does not
% discriminate on its own; it is used here as a difference, not a level.
A.outageColumn      = 'servSINR_min_dB';
A.sinrOutageDb      = 0.0;
A.marginColumn      = 'servSINR_mean_dB';
A.marginRef_dB      = 10.0;    % SINR loss counted as total margin erosion
A.outageWt          = 0.5;     % within-dR split
A.marginWt          = 0.5;     % within-dR split

% ---- Responsiveness term, dL --------------------------------------------
% No packet latency is logged and retxRate is identically zero under the
% abstracted PHY, so delay is reconstructed from two measured mechanisms:
%   1. handover interruption, hoCount_win x (prep + exec) per window
%   2. traffic gating, the wait for the next on-period once the aerial UE
%      adopts the bursty terrestrial profile (uplink off-time 2.5 s)
A.hoInterrupt_s     = 0.090;   % cfg.handover.hoPrepDelay + hoExecDelay
A.ulOffTime_s       = 2.5;     % cfg.traffic.terrestrial.ul offTime
A.latencyBudget_s   = 1.0;     % C2 responsiveness budget; normalises dL

% ---- Link volatility term, dV -------------------------------------------
% A link can hold its mean quality and its outage rate while becoming too
% unstable to fly a control loop over. Neither dR nor dL captures that mode.
% Measured against the honest baseline, within-window serving SINR variance
% rises by a factor of 6.7 under lowAltitude, against 0.94 in the null
% condition (trafficReshaping, which does not move the aircraft).
%
% The ratio is taken in logarithm because variance ratios are multiplicative.
% A linear ratio bounds improvement at 1 while leaving degradation unbounded,
% which breaks the symmetry that signed costs require. Under the log form a
% volatilityRatio-fold increase carries unit cost, a doubling carries 0.30 and
% a halving carries -0.30.
A.volatilityColumn  = 'servSINR_var_dB2';
A.volatilityRatio   = 10.0;    % fold-increase in variance counted as unit cost

% ---- Mission duration term, dK ------------------------------------------
% 'combined' swaps the aerial speed band for the terrestrial one, so the same
% mission takes mean(15,30)/mean(1,5) = 7.5x longer. That penalty is invisible
% in the feature CSV and has to come from the configuration.
A.aerialSpeed_ms      = [15 30];
A.terrestrialSpeed_ms = [1 5];
A.durationConditions  = {'combined'};   % conditions that reduce cruise speed

% ---- Mission profiles: weights on [dT dR dL dV dK], each row sums to 1 --
% The weights encode what a mission values when it degrades. No single
% assignment is correct for every mission, so three are declared and every
% result is reported under each; the weighting then enters the analysis as a
% sensitivity study rather than an assumption. They reorder the conditions
% rather than rescaling them, which is what makes reporting all three useful.
%
%   reconnaissance   returns sensor or video data; lost payload is mission
%                    failure and everything else is secondary
%   remotePiloting   flown continuously over the cellular link with no payload
%                    return; reliability, responsiveness and stability dominate
%   terminalApproach must reach a location within a bounded time; duration
%                    carries the greatest weight and payload almost none
A.profiles.reconnaissance   = [0.50 0.15 0.10 0.15 0.10];
A.profiles.remotePiloting   = [0.05 0.30 0.30 0.25 0.10];
A.profiles.terminalApproach = [0.05 0.25 0.15 0.15 0.40];

% ---- Aggregation and sign -----------------------------------------------
A.aggregation       = 'weighted';   % 'weighted' | 'chebyshev'
A.allowNegative     = true;         % false clamps every term at 0
A.clampLimit        = 1.0;          % terms bounded to [-limit, +limit]

% ---- Adversary capability tier per condition ---------------------------
% 0 flight or configuration change only
% 1 host software change (companion computer, application layer)
% 2 modem or baseband firmware modification
% Reported alongside C_op, never summed into it. None of the three implemented
% conditions reaches tier 2: no policy here requires modifying the modem.
A.tier.lowAltitude      = 0;
A.tier.trafficReshaping = 1;
A.tier.combined         = 1;

% ---- Window matching ----------------------------------------------------
A.matchWindowCount  = true;    % truncate honest to the evasive window count
A.warmupWindows     = 0;       % extra leading windows to discard, per UE

% ---- Reporting ----------------------------------------------------------
A.bootstrapN        = 2000;
A.ciLevel           = 0.95;

% =========================================================================
% ==========================  END ADJUSTERS  ==============================
% =========================================================================

here = fileparts(mfilename('fullpath'));

p = inputParser;
p.addParameter('Profile', 'all',  @(x) ischar(x) || isstring(x));
p.addParameter('DataDir', fullfile(here, 'data'), @(x) ischar(x) || isstring(x));
p.addParameter('Export',  true,   @islogical);
p.addParameter('Verbose', true,   @islogical);
p.parse(varargin{:});
opt = p.Results;

if nargin < 1 || isempty(condition), condition = 'all'; end
if nargin < 2, seed = []; end
condition = string(condition);

dataDir    = char(opt.DataDir);
honestDir  = fullfile(dataDir, 'honest');
evasiveDir = fullfile(dataDir, 'evasive');
assert(isfolder(honestDir),  'Honest data folder not found: %s',  honestDir);
assert(isfolder(evasiveDir), 'Evasive data folder not found: %s', evasiveDir);

profileNames = fieldnames(A.profiles);
if ~strcmpi(opt.Profile, 'all')
    assert(isfield(A.profiles, char(opt.Profile)), ...
        'Unknown mission profile "%s". Defined: %s', ...
        opt.Profile, strjoin(profileNames, ', '));
    profileNames = {char(opt.Profile)};
end

conds = listConditions(evasiveDir);
if ~strcmpi(condition, "all")
    assert(any(strcmpi(conds, condition)), ...
        'Condition "%s" not found under %s. Present: %s', ...
        condition, evasiveDir, strjoin(cellstr(conds), ', '));
    conds = condition;
end

jobs = struct('condition', {}, 'scenario', {}, 'seed', {}, 'file', {});
for ci = 1:numel(conds)
    files = dir(fullfile(evasiveDir, char(conds(ci)), 'features_*_seed*.csv'));
    for fi = 1:numel(files)
        [sc, sd] = parseFeatureName(files(fi).name);
        if isempty(sc), continue, end
        if ~isempty(seed) && ~ismember(sd, seed), continue, end
        jobs(end+1) = struct('condition', conds(ci), 'scenario', string(sc), ...
            'seed', sd, 'file', fullfile(files(fi).folder, files(fi).name)); %#ok<AGROW>
    end
end
assert(~isempty(jobs), 'No evasive runs matched condition "%s" and the given seeds.', condition);

if opt.Verbose
    fprintf('phase7_MissionCost: pricing %d run(s) across %d condition(s).\n', ...
        numel(jobs), numel(conds));
end

honestCache = containers.Map('KeyType','char','ValueType','any');
rows = {};
R = struct([]);

for k = 1:numel(jobs)
    j = jobs(k);

    E = runMetrics(j.file, A, []);

    hFile = fullfile(honestDir, sprintf('features_%s_seed%d.csv', j.scenario, j.seed));
    if ~isfile(hFile)
        warning('phase7_MissionCost:noBaseline', ...
            'No honest baseline %s; skipping %s seed %d.', hFile, j.condition, j.seed);
        continue
    end
    % Honest metrics depend on the evasive window count through the
    % truncation, so the cache key carries it.
    hKey = sprintf('%s_%d_%d', j.scenario, j.seed, E.windowsPerUE);
    if ~isKey(honestCache, hKey)
        honestCache(hKey) = runMetrics(hFile, A, E.windowsPerUE);
    end
    H = honestCache(hKey);

    % Span matching is a correctness condition, not a convenience. Every
    % metric here is already intensive (a per-window mean, rate or fraction),
    % so dividing by run duration would change nothing: the bias does not come
    % from counting more windows, it comes from the extra 20 s of the honest
    % run sampling different trajectory geometry. Measured over the 15 honest
    % runs, using all 50 windows instead of the first 30 shifts mean serving
    % SINR by up to 24% on a single seed. Only truncation removes that.
    if H.windowsPerUE ~= E.windowsPerUE
        error('phase7_MissionCost:spanMismatch', ...
            ['Window count mismatch for %s %s seed %d: honest %d, evasive %d. ' ...
             'The honest hold-out runs to %d windows and must be truncated to ' ...
             'the evasive count before any metric is formed. Check ' ...
             'A.matchWindowCount and A.warmupWindows.'], ...
            j.condition, j.scenario, j.seed, H.windowsPerUE, E.windowsPerUE, ...
            H.windowsPerUE);
    end

    d = computeDeltas(H, E, j.condition, A);
    tier = conditionTier(j.condition, A);

    for pi = 1:numel(profileNames)
        pn = profileNames{pi};
        w  = A.profiles.(pn);
        v  = [d.dT d.dR d.dL d.dV d.dK];
        assert(numel(w) == numel(v), ...
            'Profile "%s" has %d weights; the model has %d terms.', ...
            pn, numel(w), numel(v));
        switch lower(A.aggregation)
            case 'weighted',  cop = sum(w .* v);
            case 'chebyshev', cop = max(w .* v);
            otherwise, error('Unknown A.aggregation: %s', A.aggregation);
        end

        rows{end+1} = { j.condition, j.scenario, j.seed, string(pn), tier, ...
            cop, d.dT, d.dR, d.dL, d.dV, d.dK, d.dR_outage, d.dR_margin, ...
            H.payloadMbps, E.payloadMbps, ...
            H.outageFrac,  E.outageFrac, ...
            H.sinrMeanDb,  E.sinrMeanDb, ...
            H.sinrVarDb2,  E.sinrVarDb2, ...
            H.delaySec,    E.delaySec, ...
            H.hoPerWin,    E.hoPerWin, ...
            d.speedRatio, H.windowsPerUE, E.windowsPerUE, E.nAerialUE }; %#ok<AGROW>
    end

    rec = struct('condition', j.condition, 'scenario', j.scenario, 'seed', j.seed, ...
        'honest', H, 'evasive', E, 'deltas', d, 'tier', tier);
    if isempty(R), R = rec; else, R(end+1) = rec; end %#ok<AGROW>
end

assert(~isempty(rows), 'phase7_MissionCost: no run produced a cost.');

C = cell2table(vertcat(rows{:}), 'VariableNames', { ...
    'condition','scenario','seed','profile','tier','C_op', ...
    'dT','dR','dL','dV','dK','dR_outage','dR_margin', ...
    'payload_honest_Mbps','payload_evade_Mbps', ...
    'outage_honest','outage_evade', ...
    'sinr_honest_dB','sinr_evade_dB', ...
    'sinrVar_honest_dB2','sinrVar_evade_dB2', ...
    'delay_honest_s','delay_evade_s', ...
    'ho_honest_perWin','ho_evade_perWin', ...
    'speedRatio','nWin_honest','nWin_evade','nAerialUE'});
C = sortrows(C, {'profile','condition','seed'});

if opt.Verbose, printReport(C, A); end

if opt.Export
    outDir = fullfile(here, 'results');
    if ~isfolder(outDir), mkdir(outDir); end
    stamp = char(datetime('now','Format','yyyyMMdd_HHmmss'));

    perRun = fullfile(outDir, sprintf('phase7_missioncost_perseed_%s.csv', stamp));
    writetable(C, perRun);

    S = summarise(C, A);
    agg = fullfile(outDir, sprintf('phase7_missioncost_summary_%s.csv', stamp));
    writetable(S, agg);

    if opt.Verbose
        fprintf('\nWritten:\n  %s\n  %s\n', perRun, agg);
        fprintf(['\nFor the frontier: join the per-seed file to the Phase 8 ' ...
                 'per-run detection\nmetrics on (condition, scenario, seed) ' ...
                 'and plot C_op against TPR at 1%% FPR,\none marker per seed, ' ...
                 'one panel per mission profile.\n']);
    end
end

end % ===================== end main function =========================


% =========================================================================
% SUBFUNCTIONS
% =========================================================================

function conds = listConditions(evasiveDir)
%LISTCONDITIONS  Sub-folders of data/evasive, one per evasion condition.
d = dir(evasiveDir);
d = d([d.isdir]);
names = string({d.name});
names = names(~startsWith(names, '.'));
conds = names(:)';
end


function [scenario, seed] = parseFeatureName(name)
%PARSEFEATURENAME  features_<scenario>_seed<NN>.csv
tok = regexp(name, '^features_([A-Za-z]+)_seed(\d+)\.csv$', 'tokens', 'once');
if isempty(tok)
    scenario = ''; seed = NaN;
else
    scenario = tok{1}; seed = str2double(tok{2});
end
end


function M = runMetrics(csvFile, A, limitWindows)
%RUNMETRICS  Reduce one feature CSV to the scalars the cost model needs.
%
%   Aerial UEs only: the mission cost is borne by the drone, not by the
%   terrestrial population sharing the cell.
%
%   limitWindows, when supplied, truncates each UE to its first N windows so
%   the honest hold-out (50 windows at the Phase 5 run length) is compared
%   against the evasive runs (30) over a matched mission span.

T = readtable(csvFile, 'VariableNamingRule', 'preserve');

need = {'ueID','label','winStart_s','hoCount_win', ...
        A.payloadColumn, A.outageColumn, A.marginColumn, A.volatilityColumn};
missing = need(~ismember(need, T.Properties.VariableNames));
assert(isempty(missing), 'Column(s) %s missing from %s.', ...
    strjoin(missing, ', '), csvFile);

T = T(T.label == 1, :);
assert(height(T) > 0, 'No aerial UE rows in %s.', csvFile);
T = sortrows(T, {'ueID','winStart_s'});

ues = unique(T.ueID);
nUE = numel(ues);
perUE = struct('payload', nan(nUE,1), 'outage', nan(nUE,1), ...
               'sinr', nan(nUE,1), 'var', nan(nUE,1), 'ho', nan(nUE,1), ...
               'idle', nan(nUE,1), 'nWin', nan(nUE,1));

hasIdle = ismember('trafficIdle_frac', T.Properties.VariableNames);

for i = 1:nUE
    ti = T(T.ueID == ues(i), :);

    if A.warmupWindows > 0 && height(ti) > A.warmupWindows
        ti = ti(A.warmupWindows+1:end, :);
    end
    if A.matchWindowCount && ~isempty(limitWindows) && height(ti) > limitWindows
        ti = ti(1:limitWindows, :);
    end

    perUE.nWin(i)    = height(ti);
    perUE.payload(i) = mean(ti.(A.payloadColumn), 'omitnan') / 1e6;   % Mbps
    perUE.outage(i)  = mean(ti.(A.outageColumn) < A.sinrOutageDb, 'omitnan');
    perUE.sinr(i)    = mean(ti.(A.marginColumn), 'omitnan');
    perUE.var(i)     = mean(ti.(A.volatilityColumn), 'omitnan');
    perUE.ho(i)      = mean(ti.hoCount_win, 'omitnan');
    if hasIdle
        perUE.idle(i) = mean(ti.trafficIdle_frac, 'omitnan');
    else
        perUE.idle(i) = 0;
    end
end

M = struct();
M.file          = csvFile;
M.nAerialUE     = nUE;
M.windowsPerUE  = round(median(perUE.nWin));
M.payloadMbps   = mean(perUE.payload, 'omitnan');   % mean throughput per second
M.outageFrac    = mean(perUE.outage,  'omitnan');
M.sinrMeanDb    = mean(perUE.sinr,    'omitnan');
M.sinrVarDb2    = mean(perUE.var,     'omitnan');
M.hoPerWin      = mean(perUE.ho,      'omitnan');
M.idleFrac      = mean(perUE.idle,    'omitnan');
M.delaySec      = delayProxy(M.hoPerWin, M.idleFrac, A);
M.perUE         = perUE;
end


function L = delayProxy(hoPerWin, idleFrac, A)
%DELAYPROXY  Added delivery delay, seconds, from two measured mechanisms.
%
%   Handover interruption: each handover costs preparation plus execution
%   delay during which the UE cannot transmit, so the expected delay added
%   per window is the handover rate times that duration.
%
%   Traffic gating: once the aerial UE adopts the bursty terrestrial uplink
%   profile it can only transmit during on-periods. A sample generated
%   uniformly waits half the off-time on average, conditional on arriving
%   during one, which occurs with probability trafficIdle_frac.
%
%   The two pull in opposite directions for the combined condition: reducing
%   cruise speed cuts handovers while reshaping traffic adds gating delay.

L = hoPerWin * A.hoInterrupt_s + idleFrac * (A.ulOffTime_s / 2);
end


function d = computeDeltas(H, E, condition, A)
%COMPUTEDELTAS  Signed evasive-versus-honest degradation, paired on seed.
%
%   Positive is a cost to the drone, negative is a benefit. Terms are bounded
%   to +/- A.clampLimit, and to [0, limit] when A.allowNegative is false.

d = struct();

% --- dT payload deficit --------------------------------------------------
if H.payloadMbps > 0
    d.dT = bound(1 - E.payloadMbps / H.payloadMbps, A);
else
    d.dT = 0;
end

% --- dR link degradation: realised outage plus margin erosion ------------
% Outage, renormalised by the honest run's headroom so the term is a
% proportion of the reliability that was available to lose.
d.dR_outage = bound((E.outageFrac - H.outageFrac) / max(1 - H.outageFrac, eps), A);

% Margin erosion. Signed: descending reduces the number of interfering gNBs
% in line of sight as well as the serving link quality, so serving SINR
% improves in some seeds and the term is legitimately negative there.
d.dR_margin = bound((H.sinrMeanDb - E.sinrMeanDb) / max(A.marginRef_dB, eps), A);

d.dR = bound(A.outageWt * d.dR_outage + A.marginWt * d.dR_margin, A);

% --- dL responsiveness ---------------------------------------------------
d.dL = bound((E.delaySec - H.delaySec) / max(A.latencyBudget_s, eps), A);

% --- dV link volatility --------------------------------------------------
% Log ratio, so that improvement and degradation are symmetric and a single
% unstable seed cannot dominate the condition mean. Signed: the combined
% condition reduces variance below the honest baseline, because slowing the
% aircraft stabilises the link by more than descending destabilises it.
vh = max(H.sinrVarDb2, eps);
ve = max(E.sinrVarDb2, eps);
if isfinite(vh) && isfinite(ve) && A.volatilityRatio > 1
    d.dV = bound(log(ve / vh) / log(A.volatilityRatio), A);
else
    d.dV = 0;
end

% --- dK mission duration -------------------------------------------------
vH = mean(A.aerialSpeed_ms);
if any(strcmpi(condition, A.durationConditions))
    vE = mean(A.terrestrialSpeed_ms);
else
    vE = vH;
end
d.speedRatio = vE / vH;
d.dK = bound(1 - d.speedRatio, A);
end


function y = bound(x, A)
%BOUND  Clamp to [-limit, +limit], or [0, limit] when signs are disallowed.
if isnan(x), y = 0; return, end
lo = -A.clampLimit;
if ~A.allowNegative, lo = 0; end
y = min(A.clampLimit, max(lo, x));
end


function t = conditionTier(condition, A)
%CONDITIONTIER  Ordinal adversary capability. Reported, never summed.
c = char(condition);
if isfield(A.tier, c), t = A.tier.(c); else, t = 1; end
end


function S = summarise(C, A)
%SUMMARISE  Mean C_op with bootstrap CI across seeds, per condition/profile.

[g, cond, pr] = findgroups(C.condition, C.profile);
n = max(g);
condition = strings(n,1); profile = strings(n,1);
tier = zeros(n,1); nSeeds = zeros(n,1); nBenefit = zeros(n,1);
C_mean = zeros(n,1); C_lo = zeros(n,1); C_hi = zeros(n,1);
dT = zeros(n,1); dR = zeros(n,1); dL = zeros(n,1);
dV = zeros(n,1); dK = zeros(n,1);

alpha = 1 - A.ciLevel;
for i = 1:n
    m = (g == i);
    x = C.C_op(m);
    condition(i) = cond(i); profile(i) = pr(i);
    tier(i)     = C.tier(find(m,1));
    nSeeds(i)   = numel(x);
    nBenefit(i) = sum(C.dR_margin(m) < 0);   % seeds where the link improved
    C_mean(i)   = mean(x);
    dT(i) = mean(C.dT(m)); dR(i) = mean(C.dR(m)); dL(i) = mean(C.dL(m));
    dV(i) = mean(C.dV(m)); dK(i) = mean(C.dK(m));
    if numel(x) > 1
        bs = zeros(A.bootstrapN,1);
        for b = 1:A.bootstrapN
            bs(b) = mean(x(randi(numel(x), numel(x), 1)));
        end
        C_lo(i) = quantile(bs, alpha/2);
        C_hi(i) = quantile(bs, 1-alpha/2);
    else
        C_lo(i) = NaN; C_hi(i) = NaN;
    end
end

S = table(condition, profile, tier, nSeeds, nBenefit, ...
    C_mean, C_lo, C_hi, dT, dR, dL, dV, dK);
S = sortrows(S, {'profile','C_mean'});
end


function printReport(C, A)
%PRINTREPORT  Console summary, one block per mission profile.

S = summarise(C, A);
profiles = unique(S.profile);

fprintf('\n');
fprintf('=========================================================================\n');
fprintf(' Phase 7 mission cost | payload=%s | outage: %s < %.1f dB\n', ...
    A.payloadColumn, A.outageColumn, A.sinrOutageDb);
fprintf(' margin: %s over %.1f dB | volatility: %s over %.0fx\n', ...
    A.marginColumn, A.marginRef_dB, A.volatilityColumn, A.volatilityRatio);
fprintf(' agg=%s | signed=%d\n', A.aggregation, A.allowNegative);
fprintf('=========================================================================\n');

for pi = 1:numel(profiles)
    pn = profiles(pi);
    B = S(S.profile == pn, :);
    w = A.profiles.(char(pn));
    fprintf('\n-- %-16s weights [dT dR dL dV dK] = [%.2f %.2f %.2f %.2f %.2f]\n', ...
        char(pn), w(1), w(2), w(3), w(4), w(5));
    fprintf('   %-18s %4s %4s %4s  %-24s %s\n', ...
        'condition','tier','n','ben','C_op [95% CI]','dT / dR / dL / dV / dK');
    fprintf('   %s\n', repmat('-', 1, 92));
    for i = 1:height(B)
        if isnan(B.C_lo(i))
            ci = sprintf('%+.3f (n=1)', B.C_mean(i));
        else
            ci = sprintf('%+.3f [%+.3f, %+.3f]', B.C_mean(i), B.C_lo(i), B.C_hi(i));
        end
        fprintf(['   %-18s %4d %4d %4d  %-24s ' ...
                 '%+.2f / %+.2f / %+.2f / %+.2f / %+.2f\n'], ...
            char(B.condition(i)), B.tier(i), B.nSeeds(i), B.nBenefit(i), ci, ...
            B.dT(i), B.dR(i), B.dL(i), B.dV(i), B.dK(i));
    end
end

fprintf(['\n   ben = seeds where the evasion improved serving SINR, so the\n' ...
         '   margin component of dR is negative for that run.\n']);
fprintf(['   Tier 0 flight or configuration change, 1 host software, ' ...
         '2 modem firmware.\n   Tier is ordinal and is not included in C_op.\n\n']);
end
