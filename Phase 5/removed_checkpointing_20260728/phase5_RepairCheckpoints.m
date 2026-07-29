function R = phase5_RepairCheckpoints(cfg, action)
%phase5_RepairCheckpoints Audit and repair the checkpoint state of a batch.
%
%   R = phase5_RepairCheckpoints()                 audit only, uses phase5_Config
%   R = phase5_RepairCheckpoints(CFG)              audit only
%   R = phase5_RepairCheckpoints(CFG, "clear")     archive the short runs
%   R = phase5_RepairCheckpoints(CFG, "restamp")   correct lying markers in place
%
%   WHY THIS EXISTS
%   A checkpoint marker can outlive the truth it recorded. An earlier
%   version of the salvage path wrote simReached = simulationTime when it
%   closed out an interrupted run, so a run cut off after one 5 s segment
%   of a 60.5 s simulation was recorded as a finished full-length run.
%   Every later batch then read "complete", skipped it, and reported
%   nothing to do. The marker cannot be trusted to detect that state, so
%   this function measures each run from its FEATURE CSV instead: the
%   largest winEnd_s in the file is a lower bound on the simulated time
%   actually reached, independent of what any marker claims.
%
%   ACTIONS
%     "audit"   (default) report only, change nothing.
%     "clear"   move the CSV, its replay bundle and its marker for every
%               short run into <dataDir>/superseded_<stamp>/, so the next
%               batch treats those runs as fresh and re-simulates them at
%               full length. Nothing is deleted: the archived files stay
%               available for comparison.
%     "restamp" keep the files in place but rewrite each marker with the
%               measured simReached and the truncated flag set, so the
%               rows are kept and remain identifiable as short. Use this
%               when the partial rows are wanted and re-simulating is not.
%
%   The returned table has one row per enumerated run: what is on disk,
%   what the marker claims, what the CSV measures, and the verdict.
%
%   See also phase5_RunBatch, phase5_Checkpoint, phase5_MergeDataset.

    if nargin < 1 || isempty(cfg), cfg = phase5_Config(); end
    if nargin < 2 || isempty(action), action = "audit"; end
    action = lower(string(action));
    assert(ismember(action, ["audit" "clear" "restamp"]), ...
        'phase5_RepairCheckpoints:badAction', ...
        'action must be "audit", "clear" or "restamp", got "%s".', action);

    here = fileparts(mfilename('fullpath'));
    addpath(fullfile(here, 'core', 'functions'));

    if strlength(string(cfg.batch.dataDir)) == 0
        cfg.batch.dataDir = string(fullfile(here, 'data'));
    end
    dataDir = char(cfg.batch.dataDir);

    %% ---- enumerate exactly as the batch does ----------------------------
    seeds = cfg.batch.seedRange(:)';
    cycle = string(cfg.batch.scenarioCycle(:))';
    nRuns = min(numel(seeds), cfg.batch.maxRuns);
    seeds = seeds(1:nRuns);
    scenarios = cycle(mod((0:nRuns-1), numel(cycle)) + 1);

    simTotal  = cfg.window.simulationTime;
    windowLen = cfg.window.windowLen;

    %% ---- measure every run ----------------------------------------------
    rows = cell(nRuns, 1);
    for i = 1:nRuns
        rc = struct('scenario', scenarios(i), 'seed', seeds(i), ...
            'outputDir', string(dataDir), 'simulationTime', simTotal);
        p    = phase5_Checkpoint('paths', rc);
        info = phase5_Checkpoint('info', rc);

        csvExists = exist(p.csv, 'file') == 2;
        [nRowsCsv, maxWinEnd] = csvExtent(p.csv);

        % Verdict, from the CSV first and the marker only as support. A run
        % is short when its last window ends more than one window before
        % the configured end: the final window of a full run starts at
        % simTotal - windowLen at the latest, so maxWinEnd of a full run is
        % within a stride of simTotal.
        if ~csvExists
            verdict = "missing";
        elseif isnan(maxWinEnd)
            verdict = "unreadable";
        elseif maxWinEnd < simTotal - windowLen - 1e-9
            verdict = "short";
        elseif info.exists && info.truncated
            verdict = "short";
        elseif ~info.exists
            verdict = "no-marker";
        elseif ~info.complete
            verdict = "partial";
        else
            verdict = "full";
        end

        rows{i} = struct('runIdx', i, 'scenario', scenarios(i), ...
            'seed', seeds(i), 'csvExists', double(csvExists), ...
            'markerExists', double(info.exists), ...
            'markerComplete', double(info.complete), ...
            'markerSimReached', info.simReached, ...
            'csvMaxWinEnd_s', maxWinEnd, 'simTotal_s', simTotal, ...
            'numRows', nRowsCsv, 'verdict', verdict, ...
            'markerLies', double(info.complete && ~isnan(maxWinEnd) && ...
                maxWinEnd < simTotal - windowLen - 1e-9 && ~info.truncated));
    end
    R = struct2table([rows{:}]);

    %% ---- report -----------------------------------------------------------
    fprintf('\nPhase 5 checkpoint audit: %d run(s) in %s\n', nRuns, dataDir);
    for v = ["full" "short" "partial" "no-marker" "missing" "unreadable"]
        k = sum(R.verdict == v);
        if k > 0, fprintf('  %-11s %d\n', v, k); end
    end
    bad = find(R.verdict == "short" | R.verdict == "unreadable")';
    for i = bad
        fprintf(['  %s seed %d: rows end at %.2f s of %.2f s (%g row(s))%s\n'], ...
            R.scenario(i), R.seed(i), R.csvMaxWinEnd_s(i), simTotal, ...
            R.numRows(i), ternary(R.markerLies(i) == 1, ...
                ' -- marker claims a full complete run', ''));
    end
    if isempty(bad)
        fprintf('  Nothing to repair.\n\n');
        return;
    end

    %% ---- repair ------------------------------------------------------------
    switch action
        case "audit"
            fprintf(['\n  Audit only. Re-run these at full length with:\n' ...
                '    phase5_RepairCheckpoints(cfg, "clear"); phase5_RunBatch(cfg)\n' ...
                '  or keep the partial rows and just correct the markers with:\n' ...
                '    phase5_RepairCheckpoints(cfg, "restamp")\n\n']);

        case "clear"
            stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
            archive = fullfile(dataDir, ['superseded_' stamp]);
            if ~exist(archive, 'dir'), mkdir(archive); end
            nMoved = 0;
            for i = bad
                rc = struct('scenario', R.scenario(i), 'seed', R.seed(i), ...
                    'outputDir', string(dataDir), 'simulationTime', simTotal);
                p = phase5_Checkpoint('paths', rc);
                replay = fullfile(dataDir, sprintf('replay_%s_seed%d.mat', ...
                    R.scenario(i), R.seed(i)));
                for f = {p.csv, p.marker, replay}
                    if exist(f{1}, 'file') == 2
                        movefile(f{1}, fullfile(archive, nameOf(f{1})), 'f');
                        nMoved = nMoved + 1;
                    end
                end
            end
            fprintf(['\n  Archived %d file(s) from %d short run(s) to\n    %s\n' ...
                '  Those runs are now fresh; phase5_RunBatch will re-simulate ' ...
                'them at %.2f s.\n\n'], nMoved, numel(bad), archive, simTotal);

        case "restamp"
            for i = bad
                rc = struct('scenario', R.scenario(i), 'seed', R.seed(i), ...
                    'outputDir', string(dataDir), 'simulationTime', simTotal);
                reached = R.csvMaxWinEnd_s(i);
                phase5_Checkpoint('write', rc, reached, true, ...
                    R.numRows(i), NaN, true);
                fprintf('  restamped %s seed %d: simReached %.2f s, truncated\n', ...
                    R.scenario(i), R.seed(i), reached);
            end
            fprintf(['\n  Markers corrected. The runs stay skipped, but the ' ...
                'manifest now flags them truncated.\n\n']);
    end
end

%% ==========================================================================
function [nRows, maxWinEnd] = csvExtent(csvPath)
%csvExtent Data-row count and the largest winEnd_s in a feature CSV.
%   Parsed by hand rather than with readtable: the file is the one
%   artefact whose format is contractually fixed (writeFeatureCSV), and a
%   plain text scan cannot be perturbed by import-option guessing on a
%   file that a crash may have left without its final newline.
    nRows = 0; maxWinEnd = NaN;
    if exist(csvPath, 'file') ~= 2, return; end
    fid = fopen(csvPath, 'r');
    if fid < 0, return; end
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>

    header = fgetl(fid);
    if ~ischar(header), return; end
    cols = strsplit(header, ',');
    col  = find(strcmp(cols, 'winEnd_s'), 1);

    while true
        ln = fgetl(fid);
        if ~ischar(ln), break; end
        if isempty(strtrim(ln)), continue; end
        nRows = nRows + 1;
        if isempty(col), continue; end
        parts = strsplit(ln, ',');
        if numel(parts) < col, continue; end
        v = str2double(parts{col});
        if ~isnan(v), maxWinEnd = max([maxWinEnd v]); end
    end
end

%% ==========================================================================
function n = nameOf(f)
    [~, b, e] = fileparts(f);
    n = [b e];
end

%% ==========================================================================
function s = ternary(cond, a, b)
    if cond, s = a; else, s = b; end
end
