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
%     'Profile'   'reconnaissance' | 'remotePiloting' | 'terminalApproach' | 'all'
%     'DataDir'   override the data folder
%     'Export'    write results/phase7_missioncost_*.csv           (default true)
%     'Verbose'   console report                                   (default true)
%
%   COST MODEL
%     Four priced terms, each an evasive-versus-honest difference paired on the
%     same seed and scenario:
%
%       dR  link degradation     realised outage plus SINR margin erosion
%       dL  responsiveness       handover interruption
%       dV  link volatility      growth in within-window serving SINR variance
%       dK  mission duration     time penalty from reduced cruise speed
%
%     C_op = w.[dR dL dV dK] under a declared mission profile, or the Chebyshev
%     max if compensation between terms is not acceptable.
%
%     A fifth quantity, the uplink payload deficit, is computed and written to
%     the per-seed table as dT_unpriced but is NEVER summed into C_op. It was
%     withdrawn with the traffic block, because the payload change observed in
%     the evasive corpus is produced by the application traffic profile rather
%     than by the flight policy, and pricing it would attribute a traffic
%     effect to a manoeuvre. It is retained in the output for audit only.
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
%     inter-cell interference, so descending sometimes raises serving SINR,
%     and slowing the aircraft stabilises the link. Clamping at zero would
%     hide the cases in which evasion is free, or better than free, in link
%     terms.
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
%     truncated to the evasive window count before any metric is formed.
%     Comparing 50 honest windows against 30 evasive ones silently compares
%     different mission spans.
%
%   Requires MATLAB R2024b. Part of the uav_detect Phase 7 pipeline.
%   See also phase7_Config, phase7_RunBatch, phase7_VerifyCost.

% =========================================================================
% ============================  ADJUSTERS  ================================
% ==============  everything tunable lives in this block  =================
% =========================================================================

A = struct();

% ---- Conditions priced --------------------------------------------------
% trafficReshaping is withdrawn from the report with the traffic block and is
% not priced. Listing it here leaves the folder on disk untouched while
% keeping it out of every output.
A.excludeConditions = {'trafficReshaping'};

% ---- Payload, computed but NOT priced -----------------------------------
% Retained as dT_unpriced for audit. See the header note.
A.payloadColumn     = 'ulThr_bps';        % 'ulThr_bps' | 'thr_mean_bps' | 'dlThr_bps'

% ---- Link degradation term, dR ------------------------------------------
% Two parts, because they measure different failures:
%
%   outage  realised loss of link, the fraction of windows whose worst SINR
%           falls below the demodulation floor.
%   margin  erosion of headroom that has not yet become failure. The 20 MHz
%           abstracted PHY leaves enough margin that a large SINR loss often
%           produces no outage, so outage alone understates the cost of
%           descending.
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
% abstracted PHY, so delay is reconstructed from the mechanisms the simulator
% records:
%   1. handover interruption, hoCount_win x (prep + exec) per window
%   2. traffic gating, the wait for the next on-period under a bursty uplink
%      profile
%
% Gating is OFF by default. It fires only where a condition changes the
% application traffic profile, which is what trafficReshaping did. Leaving it
% on attributes a traffic-profile effect to a flight policy that does not
% change traffic, which is the same contamination that removed the payload
% term from the priced set.
A.hoInterrupt_s      = 0.090;  % cfg.handover.hoPrepDelay + hoExecDelay
A.ulOffTime_s        = 2.5;    % cfg.traffic.terrestrial.ul offTime
A.latencyBudget_s    = 1.0;    % C2 responsiveness budget; normalises dL
A.includeGatingDelay = false;  % true restores the pre-withdrawal behaviour

% ---- Link volatility term, dV -------------------------------------------
% A link can hold its mean quality and its outage rate while becoming too
% unstable to fly a control loop over. Neither dR nor dL captures that mode.
%
% The ratio is taken in logarithm because variance ratios are multiplicative.
% A linear ratio bounds improvement at 1 while leaving degradation unbounded,
% which breaks the symmetry that signed costs require. Under the log form a
% volatilityRatio-fold increase carries unit cost, a doubling carries 0.30 and
% a halving carries -0.30.
A.volatilityColumn  = 'servSINR_var_dB2';
A.volatilityRatio   = 10.0;    % fold-increase in variance counted as unit cost

% ---- Mission duration term, dK ------------------------------------------
% A low-speed policy swaps the aerial speed band for the terrestrial one, so
% the same mission takes mean(15,30)/mean(1,5) = 7.5x longer. That penalty is
% invisible in the feature CSV and has to come from the configuration.
%
% CRITICAL: these names must match the sub-folder names under data/evasive
% exactly. A mismatch silently zeroes dK for every row and makes every profile
% weight on duration inert. The assertions below catch it.
A.aerialSpeed_ms      = [15 30];
A.terrestrialSpeed_ms = [1 5];
A.durationConditions  = {'lowAltLowSpeed', 'combined'};

% ---- Mission profiles: weights on [dR dL dV dK], each row sums to 1 ------
% Revised after the payload term was withdrawn. The pre-withdrawal vectors on
% [dT dR dL dV dK] were:
%     reconnaissance   [0.50 0.15 0.10 0.15 0.10]
%     remotePiloting   [0.05 0.30 0.30 0.25 0.10]
%     terminalApproach [0.05 0.25 0.15 0.15 0.40]
% Simply renormalising those rows left reconnaissance and remotePiloting
% almost identical, because the payload weight was carrying reconnaissance's
% entire identity. The vectors below are rebuilt from what each mission needs
% of the link once payload volume is no longer priced.
%
%   reconnaissance   holds a sustained sensor or video return over a loiter of
%                    no fixed length. A link that is unusable or unstable ends
%                    the mission; taking longer does not. Reliability and
%                    stability dominate, duration is nearly free.
%   remotePiloting   a pilot flies the aircraft live over the link. Delay and
%                    instability are felt directly in the control loop, and
%                    endurance places a real but secondary bound on time.
%   terminalApproach must reach a point within a bounded time. Brief link
%                    degradation is survivable; arriving late is not.
A.profiles.reconnaissance   = [0.35 0.10 0.45 0.10];
A.profiles.remotePiloting   = [0.30 0.30 0.20 0.20];
A.profiles.terminalApproach = [0.15 0.05 0.10 0.70];

% ---- Aggregation and sign -----------------------------------------------
A.aggregation       = 'weighted';   % 'weighted' | 'chebyshev'
A.allowNegative     = true;         % false clamps every term at 0
A.clampLimit        = 1.0;          % terms bounded to [-limit, +limit]

% ---- Adversary capability tier per condition ---------------------------
% 0 flight or configuration change only
% 1 host software change (companion computer, application layer)
% 2 modem or baseband firmware modification
% Reported alongside C_op, never summed into it.
A.tier.lowAltitude      = 0;
A.tier.trafficReshaping = 1;
A.tier.lowAltLowSpeed   = 1;
A.tier.combined         = 1;

% ---- Window matching ----------------------------------------------------
A.matchWindowCount  = true;    % truncate honest to the evasive window count
A.warmupWindows     = 0;       % extra leading windows to discard, per UE

% ---- Reporting ----------------------------------------------------------
A.bootstrapN        = 2000;
A.ciLevel           = 0.95;

% ---- Term bookkeeping ---------------------------------------------------
A.termFields = {'dR','dL','dV','dK'};
A.termLabels = {'dR link', 'dL responsiveness', 'dV volatility', 'dK duration'};

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

% Every profile must carry one weight per priced term, and the weights must
% sum to one, or C_op is not on the scale the report states.
profileNames = fieldnames(A.profiles);
for i = 1:numel(profileNames)
    w = A.profiles.(profileNames{i});
    assert(numel(w) == numel(A.termFields), ...
        'Profile "%s" has %d weights; the model prices %d terms.', ...
        profileNames{i}, numel(w), numel(A.termFields));
    assert(abs(sum(w) - 1) < 1e-9, ...
        'Profile "%s" weights sum to %.6f, not 1.', profileNames{i}, sum(w));
end
if ~strcmpi(opt.Profile, 'all')
    assert(isfield(A.profiles, char(opt.Profile)), ...
        'Unknown mission profile "%s". Defined: %s', ...
        opt.Profile, strjoin(profileNames, ', '));
    profileNames = {char(opt.Profile)};
end

conds = listConditions(evasiveDir);

% Drop withdrawn conditions before anything is priced.
if ~isempty(A.excludeConditions)
    keep    = ~ismember(lower(cellstr(conds)), lower(A.excludeConditions));
    dropped = conds(~keep);
    conds   = conds(keep);
    if ~isempty(dropped) && opt.Verbose
        fprintf('Excluded condition(s): %s\n', strjoin(cellstr(dropped), ', '));
    end
end
assert(~isempty(conds), 'Every condition was excluded by A.excludeConditions.');

if ~strcmpi(condition, "all")
    assert(any(strcmpi(conds, condition)), ...
        'Condition "%s" not found under %s (after exclusions). Present: %s', ...
        condition, evasiveDir, strjoin(cellstr(conds), ', '));
    conds = condition;
end

% A duration-condition name that matches nothing on disk zeroes dK silently
% and makes every profile weight on duration inert.
matched = intersect(lower(cellstr(conds)), lower(A.durationConditions));
assert(~isempty(matched), ...
    ['No condition on disk matches A.durationConditions {%s}. Conditions ' ...
     'present: %s. dK would be zero for every row. Fix the names before ' ...
     'proceeding.'], strjoin(A.durationConditions, ', '), ...
    strjoin(cellstr(conds), ', '));

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
    % run sampling different trajectory geometry.
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
        v  = [d.dR d.dL d.dV d.dK];      % dT is NOT included by design
        switch lower(A.aggregation)
            case 'weighted',  cop = sum(w .* v);
            case 'chebyshev', cop = max(w .* v);
            otherwise, error('Unknown A.aggregation: %s', A.aggregation);
        end

        rows{end+1} = { j.condition, j.scenario, j.seed, string(pn), tier, ...
            cop, d.dR, d.dL, d.dV, d.dK, d.dR_outage, d.dR_margin, ...
            d.dT_unpriced, ...
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
    'dR','dL','dV','dK','dR_outage','dR_margin','dT_unpriced', ...
    'payload_honest_Mbps','payload_evade_Mbps', ...
    'outage_honest','outage_evade', ...
    'sinr_honest_dB','sinr_evade_dB', ...
    'sinrVar_honest_dB2','sinrVar_evade_dB2', ...
    'delay_honest_s','delay_evade_s', ...
    'ho_honest_perWin','ho_evade_perWin', ...
    'speedRatio','nWin_honest','nWin_evade','nAerialUE'});
C = sortrows(C, {'profile','condition','seed'});

% dK is configuration-derived and must be non-zero for a speed-reducing
% condition. A column of zeros there means the duration weights are inert.
for ci = 1:numel(conds)
    if any(strcmpi(conds(ci), A.durationConditions))
        v = C.dK(C.condition == conds(ci));
        assert(any(abs(v) > eps), ...
            ['dK is zero for every row of condition "%s", which is listed as ' ...
             'speed-reducing. Check A.durationConditions against the folder ' ...
             'names under data/evasive.'], conds(ci));
    end
end

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

    % Figures, figure-tables and the key-results file for the report.
    reportOutputs(C, S, A, here, stamp);

    if opt.Verbose
        fprintf('\nWritten:\n  %s\n  %s\n', perRun, agg);
        fprintf(['\nFor the frontier: join the per-seed file to the Phase 8 ' ...
                 'per-run detection\nmetrics on (condition, scenario, seed) ' ...
                 'and plot C_op against aerial UE-runs detected,\none panel ' ...
                 'per mission profile.\n']);
        fprintf('Run phase7_VerifyCost on the per-seed file before reporting.\n');
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
%   the honest hold-out (50 windows) is compared against the evasive runs (30)
%   over a matched mission span.

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
%DELAYPROXY  Added delivery delay, seconds, from the measured mechanisms.
%
%   Handover interruption: each handover costs preparation plus execution
%   delay during which the UE cannot transmit, so the expected delay added
%   per window is the handover rate times that duration.
%
%   Traffic gating: once a UE adopts a bursty uplink profile it can only
%   transmit during on-periods. A sample generated uniformly waits half the
%   off-time on average, conditional on arriving during one, which occurs with
%   probability trafficIdle_frac.
%
%   Gating is included only when A.includeGatingDelay is true. A policy that
%   does not alter the application traffic profile incurs no gating change,
%   and including the term regardless imports a traffic effect into a cost
%   attributed to a flight manoeuvre.

L = hoPerWin * A.hoInterrupt_s;
if A.includeGatingDelay
    L = L + idleFrac * (A.ulOffTime_s / 2);
end
end


function d = computeDeltas(H, E, condition, A)
%COMPUTEDELTAS  Signed evasive-versus-honest degradation, paired on seed.
%
%   Positive is a cost to the drone, negative is a benefit. Terms are bounded
%   to +/- A.clampLimit, and to [0, limit] when A.allowNegative is false.

d = struct();

% --- dT payload deficit: COMPUTED BUT NOT PRICED -------------------------
% Written to the output as dT_unpriced for audit. See the header note.
if H.payloadMbps > 0
    d.dT_unpriced = bound(1 - E.payloadMbps / H.payloadMbps, A);
else
    d.dT_unpriced = 0;
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
% unstable seed cannot dominate the condition mean. Signed: a low-speed
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
dR = zeros(n,1); dL = zeros(n,1); dV = zeros(n,1); dK = zeros(n,1);
dT_unpriced = zeros(n,1);

alpha = 1 - A.ciLevel;
for i = 1:n
    m = (g == i);
    x = C.C_op(m);
    condition(i) = cond(i); profile(i) = pr(i);
    tier(i)     = C.tier(find(m,1));
    nSeeds(i)   = numel(x);
    nBenefit(i) = sum(C.dR_margin(m) < 0);   % seeds where the link improved
    C_mean(i)   = mean(x);
    dR(i) = mean(C.dR(m)); dL(i) = mean(C.dL(m));
    dV(i) = mean(C.dV(m)); dK(i) = mean(C.dK(m));
    dT_unpriced(i) = mean(C.dT_unpriced(m));
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
    C_mean, C_lo, C_hi, dR, dL, dV, dK, dT_unpriced);
S = sortrows(S, {'profile','C_mean'});
end


function printReport(C, A)
%PRINTREPORT  Console summary, one block per mission profile.

S = summarise(C, A);
profiles = unique(S.profile);

fprintf('\n');
fprintf('-------------------------------------------------------------------------\n');
fprintf(' Mission profile weights on [dR dL dV dK]\n');
fprintf('-------------------------------------------------------------------------\n');
pn = fieldnames(A.profiles);
for i = 1:numel(pn)
    w = A.profiles.(pn{i});
    fprintf('   %-18s %.4f  %.4f  %.4f  %.4f   sum %.4f\n', ...
        pn{i}, w(1), w(2), w(3), w(4), sum(w));
end
fprintf('   %s\n', strjoin(A.termLabels, ' | '));
fprintf('-------------------------------------------------------------------------\n');

fprintf('\n');
fprintf('=========================================================================\n');
fprintf(' Phase 7 mission cost | four priced terms; payload computed, not priced\n');
fprintf(' outage: %s < %.1f dB | margin: %s over %.1f dB\n', ...
    A.outageColumn, A.sinrOutageDb, A.marginColumn, A.marginRef_dB);
fprintf(' volatility: %s over %.0fx | gating delay in dL: %d\n', ...
    A.volatilityColumn, A.volatilityRatio, A.includeGatingDelay);
fprintf(' agg=%s | signed=%d | clamp +/-%.1f\n', ...
    A.aggregation, A.allowNegative, A.clampLimit);
fprintf('=========================================================================\n');

for pi = 1:numel(profiles)
    pn = profiles(pi);
    B = S(S.profile == pn, :);
    w = A.profiles.(char(pn));
    fprintf('\n-- %-16s weights [dR dL dV dK] = [%.2f %.2f %.2f %.2f]\n', ...
        char(pn), w(1), w(2), w(3), w(4));
    fprintf('   %-18s %4s %4s %4s  %-24s %s\n', ...
        'condition','tier','n','ben','C_op [95% CI]','dR / dL / dV / dK   (dT unpriced)');
    fprintf('   %s\n', repmat('-', 1, 100));
    for i = 1:height(B)
        if isnan(B.C_lo(i))
            ci = sprintf('%+.3f (n=1)', B.C_mean(i));
        else
            ci = sprintf('%+.3f [%+.3f, %+.3f]', B.C_mean(i), B.C_lo(i), B.C_hi(i));
        end
        fprintf(['   %-18s %4d %4d %4d  %-24s ' ...
                 '%+.2f / %+.2f / %+.2f / %+.2f   (%+.2f)\n'], ...
            char(B.condition(i)), B.tier(i), B.nSeeds(i), B.nBenefit(i), ci, ...
            B.dR(i), B.dL(i), B.dV(i), B.dK(i), B.dT_unpriced(i));
    end
end

fprintf(['\n   ben = seeds where the evasion improved serving SINR, so the\n' ...
         '   margin component of dR is negative for that run.\n']);
fprintf(['   dT is shown in parentheses for audit only and is never summed\n' ...
         '   into C_op.\n']);
fprintf(['   Tier 0 flight or configuration change, 1 host software, ' ...
         '2 modem firmware.\n   Tier is ordinal and is not included in C_op.\n\n']);
end


% =========================================================================
% REPORT OUTPUTS
% =========================================================================

function reportOutputs(C, S, A, here, stamp)
%REPORTOUTPUTS Figures, figure-tables and the key-results file for Phase 7.
%
%   Presentation only: it re-reads what the cost model has already produced
%   and renders it, so no number here can differ from the CSVs.
%
%   The component and physical-quantity views are taken from a single mission
%   profile, because dR to dK do not depend on the profile. Only the weights
%   do, and those are what the per-profile panels of F7.1 show.

addpath(here);
R       = report_util();
figDir  = fullfile(here, 'figures');
keyFile = fullfile(here, 'results', 'phase7_key_results.txt');
R.ensureDir(figDir);
R.logNew(keyFile, 'PHASE 7 KEY RESULTS');

conds = unique(C.condition, 'stable');
scens = sort(unique(C.scenario));
profs = unique(C.profile,   'stable');
nc = numel(conds);  ns = numel(scens);  np = numel(profs);
nt = numel(A.termFields);

pal     = R.palette(nc + 1);
condCol = pal(2:nc + 1, :);
compCol = R.palette(nt);
compLbl = A.termLabels;

% One profile carries the profile-independent quantities.
Cp = C(C.profile == profs(1), :);

%% F7.1 Mean mission cost per condition and scenario, one panel per profile
mu = nan(ns, nc, np);
se = nan(ns, nc, np);
for p = 1:np
    for s = 1:ns
        for c = 1:nc
            v = C.C_op(C.profile == profs(p) & C.scenario == scens(s) & ...
                       C.condition == conds(c));
            if ~isempty(v)
                mu(s, c, p) = mean(v);
                if numel(v) > 1, se(s, c, p) = std(v) / sqrt(numel(v)); else, se(s, c, p) = 0; end
            end
        end
    end
end

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 330 * np + 70, 430]);
tl  = tiledlayout(fig, 1, np, 'Padding', 'compact', 'TileSpacing', 'compact');
yl  = [min(0, min(mu(:) - se(:), [], 'omitnan')) * 1.25, ...
       max(mu(:) + se(:), [], 'omitnan') * 1.25];
for p = 1:np
    ax = nexttile(tl); hold(ax, 'on');
    bh = bar(ax, mu(:, :, p), 'grouped', 'EdgeColor', 'none');
    for c = 1:numel(bh)
        bh(c).FaceColor = condCol(c, :);
        bh(c).FaceAlpha = 0.88;
        errorbar(ax, bh(c).XEndPoints, mu(:, c, p), se(:, c, p), 'k', 'LineStyle', 'none', ...
                 'LineWidth', 0.8, 'CapSize', 3, 'HandleVisibility', 'off');
    end
    yline(ax, 0, '-', 'Color', [0.45 0.45 0.45], 'HandleVisibility', 'off');
    set(ax, 'XTick', 1:ns, 'XTickLabel', cellstr(scens));
    ylim(ax, yl);
    if p == 1, ylabel(ax, 'Mean mission cost C_op', 'Interpreter', 'none'); end
    title(ax, char(profs(p)), 'Interpreter', 'none');
    R.styleAxes(ax);
end
legend(ax, cellstr(conds), 'Location', 'northeast', 'Box', 'off', 'FontSize', 8, ...
       'Interpreter', 'none');
title(tl, sprintf(['F7.1  Mission cost of each evasion condition, averaged over ' ...
                   '%d seeds per scenario'], ...
                  round(height(Cp) / max(1, nc * ns))), 'FontWeight', 'bold');
R.saveFig(fig, fullfile(figDir, 'F7_1_mission_cost_by_condition_scenario.png'));
close(fig);

%% F7.2 What the cost is made of
comps = zeros(nc * ns, nt);
labs  = strings(nc * ns, 1);
k = 0;
for c = 1:nc
    for s = 1:ns
        k = k + 1;
        m = (Cp.condition == conds(c)) & (Cp.scenario == scens(s));
        comps(k, :) = [mean(Cp.dR(m)), mean(Cp.dL(m)), mean(Cp.dV(m)), mean(Cp.dK(m))];
        labs(k) = conds(c) + "  " + scens(s);
    end
end

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 900 460]);
ax  = axes('Parent', fig); hold(ax, 'on');
bh  = bar(ax, comps, 'stacked', 'EdgeColor', 'none');
for i = 1:numel(bh)
    bh(i).FaceColor = compCol(i, :);
    bh(i).FaceAlpha = 0.88;
end
yline(ax, 0, '-', 'Color', [0.35 0.35 0.35], 'HandleVisibility', 'off');
set(ax, 'XTick', 1:numel(labs), 'XTickLabel', cellstr(labs), 'TickLabelInterpreter', 'none');
xtickangle(ax, 30);
ylabel(ax, 'Unweighted cost component');
legend(ax, compLbl, 'Location', 'northoutside', 'Orientation', 'horizontal', ...
       'Box', 'off', 'FontSize', 8);
title(ax, 'F7.2  What the mission cost is made of, before any profile weighting', ...
      'FontSize', 11, 'FontWeight', 'bold');
R.styleAxes(ax);
R.saveFig(fig, fullfile(figDir, 'F7_2_cost_components.png'));
close(fig);

%% F7.3 What evasion actually did to the radio link
quants = {'sinr_honest_dB',      'sinr_evade_dB',      'Mean serving SINR (dB)',        false; ...
          'outage_honest',       'outage_evade',       'Outage fraction',               false; ...
          'sinrVar_honest_dB2',  'sinrVar_evade_dB2',  'Within-window SINR variance',   true};

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 960 350]);
tl  = tiledlayout(fig, 1, size(quants, 1), 'Padding', 'compact', 'TileSpacing', 'compact');
for q = 1:size(quants, 1)
    ax = nexttile(tl); hold(ax, 'on');
    for c = 1:nc
        m = (Cp.condition == conds(c));
        scatter(ax, Cp.(quants{q, 1})(m), Cp.(quants{q, 2})(m), 34, condCol(c, :), ...
                'filled', 'MarkerFaceAlpha', 0.7, 'DisplayName', char(conds(c)));
    end
    xv  = [Cp.(quants{q, 1}); Cp.(quants{q, 2})];
    xv  = xv(isfinite(xv));
    lim = [min(xv), max(xv)];
    if quants{q, 4}
        lim  = [max(min(xv(xv > 0)), eps), max(xv)];
        shown = [lim(1) * 0.7, lim(2) * 1.4];
        set(ax, 'XScale', 'log', 'YScale', 'log');
    else
        pad   = max(0.05 * (lim(2) - lim(1)), eps);
        shown = [lim(1) - pad, lim(2) + pad];
    end
    plot(ax, lim, lim, ':', 'Color', [0.5 0.5 0.5], 'HandleVisibility', 'off');
    xlim(ax, shown); ylim(ax, shown);
    axis(ax, 'square');
    xlabel(ax, ['Honest: ' quants{q, 3}], 'Interpreter', 'none');
    ylabel(ax, 'Evasive', 'Interpreter', 'none');
    title(ax, quants{q, 3}, 'Interpreter', 'none');
    R.styleAxes(ax);
end
legend(ax, 'Location', 'southeast', 'Box', 'off', 'FontSize', 8, 'Interpreter', 'none');
title(tl, 'F7.3  Honest against evasive, paired on scenario and seed, aerial UEs only', ...
      'FontWeight', 'bold');
R.saveFig(fig, fullfile(figDir, 'F7_3_link_effects_paired.png'));
close(fig);

%% T7.1 Mission cost summary
ciTxt = strings(height(S), 1);
for i = 1:height(S)
    ciTxt(i) = R.fmtCI(S.C_mean(i), S.C_lo(i), S.C_hi(i));
end
T1 = table(S.condition, S.profile, S.tier, S.nSeeds, ciTxt, ...
    S.dR, S.dL, S.dV, S.dK, ...
    'VariableNames', {'Condition', 'Profile', 'Tier', 'Seeds', 'C_op_95pct_CI', ...
                      'dR', 'dL', 'dV', 'dK'});
R.tableFigure(T1, fullfile(figDir, 'T7_1_mission_cost_summary.png'), struct( ...
    'Title', 'T7.1  Mission cost by evasion condition and mission profile', ...
    'Note', ["";sprintf('Intervals are a %d-resample bootstrap over seeds at the %.0f%% level.', A.bootstrapN, 100 * A.ciLevel); ...
             "Four priced terms. The uplink payload deficit is computed but not priced."; ...
             "Terms are signed: a negative component is an evasion that improved that aspect of the link."; ...
             "Tier is the adversary capability required (0 flight or config, 1 host software, 2 modem firmware)."; ...
             "Tier is ordinal and is never summed into C_op."]));

%% T7.2 The measured effect on the link, per condition and scenario
rowsP = cell(nc * ns, 1);
k = 0;
for c = 1:nc
    for s = 1:ns
        k = k + 1;
        m = (Cp.condition == conds(c)) & (Cp.scenario == scens(s));
        rowsP{k} = {char(conds(c)), char(scens(s)), ...
            mean(Cp.sinr_honest_dB(m)), mean(Cp.sinr_evade_dB(m)), ...
            mean(Cp.outage_honest(m)),  mean(Cp.outage_evade(m)), ...
            mean(Cp.sinrVar_evade_dB2(m)) / max(mean(Cp.sinrVar_honest_dB2(m)), eps), ...
            mean(Cp.ho_honest_perWin(m)), mean(Cp.ho_evade_perWin(m))};
    end
end
T2 = cell2table(vertcat(rowsP{:}), 'VariableNames', ...
    {'Condition', 'Scenario', 'SINR_honest_dB', 'SINR_evasive_dB', ...
     'Outage_honest', 'Outage_evasive', 'SINR_var_ratio', ...
     'HO_honest_perWin', 'HO_evasive_perWin'});
R.tableFigure(T2, fullfile(figDir, 'T7_2_link_effects.png'), struct( ...
    'Title', 'T7.2  What each evasion condition did to the aerial link', ...
    'Note', ["";sprintf('Honest baselines are truncated to the evasive window count (%d) before any metric is formed.', ...
                     round(mean(Cp.nWin_evade))); ...
             "SINR var ratio above 1 means the link became less stable under evasion."; ...
             "Averaged over the seeds of each scenario; aerial UEs only, since the cost is borne by the drone."]));

%% Key results
[~, worst] = max(S.C_mean);
[~, cheap] = min(S.C_mean);
lines = strings(0, 1);
lines(end + 1) = sprintf('Conditions priced      : %s', strjoin(cellstr(conds), ', '));
lines(end + 1) = sprintf('Conditions excluded    : %s', strjoin(A.excludeConditions, ', '));
lines(end + 1) = sprintf('Scenarios              : %s', strjoin(cellstr(scens), ', '));
lines(end + 1) = sprintf('Mission profiles       : %s', strjoin(cellstr(profs), ', '));
lines(end + 1) = sprintf('Priced terms           : %s', strjoin(A.termFields, ', '));
lines(end + 1) = sprintf('Seeds per condition    : %d', max(S.nSeeds));
lines(end + 1) = sprintf('Aggregation            : %s, signed terms = %d, clamp +/-%.1f', ...
                         A.aggregation, A.allowNegative, A.clampLimit);
lines(end + 1) = sprintf('Gating delay in dL     : %d', A.includeGatingDelay);
lines(end + 1) = sprintf('Most expensive         : %s under %s, C_op = %.3f [%.3f, %.3f]', ...
                         S.condition(worst), S.profile(worst), S.C_mean(worst), S.C_lo(worst), S.C_hi(worst));
lines(end + 1) = sprintf('Cheapest               : %s under %s, C_op = %.3f [%.3f, %.3f]', ...
                         S.condition(cheap), S.profile(cheap), S.C_mean(cheap), S.C_lo(cheap), S.C_hi(cheap));
lines(end + 1) = sprintf('Runs where the link improved: %d of %d', ...
                         sum(Cp.dR_margin < 0), height(Cp));
lines(end + 1) = sprintf('Cost table stamp       : %s', stamp);
R.logSection(keyFile, 'D7  Mission cost of evasion', lines);
R.logTable(keyFile, T1, 12);
R.logSection(keyFile, 'D7  Measured effect on the aerial link', "");
R.logTable(keyFile, T2, 12);
R.logSection(keyFile, 'Phase 7 figures written to figures/', [""; ...
    "F7_1_mission_cost_by_condition_scenario.png  mean C_op per condition and scenario, per profile"; ...
    "F7_2_cost_components.png                     unweighted dR/dL/dV/dK decomposition"; ...
    "F7_3_link_effects_paired.png                 honest against evasive, paired per run"; ...
    "T7_1_mission_cost_summary.png                cost by condition and profile with CIs"; ...
    "T7_2_link_effects.png                        measured link effect per condition and scenario"; ...
    ""; ...
    "Each name above is written twice: <name>.png for the report, <name>.fig to edit."]);

fprintf('\nReport figures in %s\nKey results in %s\n', figDir, keyFile);
end