function varargout = phase5_RunInfo(action, cfg, varargin)
% writes and reads a small per-run outcome sidecar next to each feature CSV, so
% a batch whose client dies can still have its manifest rebuilt.

    switch string(action)
        case "write"
            varargout{1} = writeInfo(cfg, varargin{:});
        case "read"
            varargout{1} = readInfo(cfg);
        case "path"
            varargout{1} = infoPath(cfg);
        otherwise
            error('phase5_RunInfo:unknownAction', ...
                'Unknown action "%s".', action);
    end
end

function names = fieldOrder()
    names = {'scenario', 'seed', 'status', 'numRows', 'numCols', ...
        'hoCountTotal', 'hoCountAerial', 'pingPongTotal', 'wallTime_s', ...
        'simReached_s', 'truncated', 'poolWorkers', 'matlabRelease', ...
        'finishedOn', 'csvFile', 'replayFile'};
end

function p = infoPath(cfg)
    if isfield(cfg, 'outputDir') && strlength(string(cfg.outputDir)) > 0
        outDir = char(cfg.outputDir);
    else
        outDir = fullfile(fileparts(mfilename('fullpath')), '..', '..', 'data');
    end
    p = fullfile(outDir, sprintf('runinfo_%s_seed%d.csv', ...
        string(cfg.scenario), cfg.seed));
end

function p = writeInfo(cfg, summary)
% writes one row describing how this run turned out.
    p = infoPath(cfg);
    names = fieldOrder();

    v = struct();
    v.scenario      = string(cfg.scenario);
    v.seed          = cfg.seed;
    v.status        = "ok";
    v.numRows       = getf(summary, 'numRows', NaN);
    v.numCols       = getf(summary, 'numCols', NaN);
    v.hoCountTotal  = getf(summary, 'hoCountTotal', NaN);
    v.hoCountAerial = getf(summary, 'hoCountAerial', NaN);
    v.pingPongTotal = getf(summary, 'pingPongTotal', NaN);
    v.wallTime_s    = getf(summary, 'wallTime_s', NaN);
    v.simReached_s  = getf(summary, 'simReached_s', cfg.simulationTime);
    v.truncated     = double(getf(summary, 'truncated', false));
    v.poolWorkers   = getf(cfg, 'poolWorkers', NaN);
    v.matlabRelease = string(version('-release'));
    v.finishedOn    = string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    v.csvFile       = string(getf(summary, 'csvPath', ""));
    v.replayFile    = string(getf(summary, 'replayPath', ""));

    tmp = [p '.tmp'];
    fid = fopen(tmp, 'w');
    if fid < 0
        warning('phase5_RunInfo:openFailed', ...
            'Could not write %s; this run will need its row rebuilt from its CSV.', tmp);
        p = "";
        return;
    end
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid, '%s\n', strjoin(names, ','));
    parts = cell(1, numel(names));
    for c = 1:numel(names)
        parts{c} = fmtField(v.(names{c}));
    end
    fprintf(fid, '%s\n', strjoin(parts, ','));
    clear cleaner;                      % close before renaming
    movefile(tmp, p, 'f');
end

function s = readInfo(cfg)
% reads the sidecar back as a struct, or [] when there is none.
    s = [];
    p = infoPath(cfg);
    if exist(p, 'file') ~= 2, return; end
    fid = fopen(p, 'r');
    if fid < 0, return; end
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
    hdr = fgetl(fid);
    row = fgetl(fid);
    if ~ischar(hdr) || ~ischar(row), return; end

    names = strsplit(hdr, ',');
    vals  = strsplit(row, ',', 'CollapseDelimiters', false);
    if numel(vals) < numel(names), return; end
    s = struct();
    for c = 1:numel(names)
        raw = strip(string(vals{c}), '"');
        num = str2double(raw);
        % numeric where it parses, text otherwise
        if ~isnan(num) || raw == "NaN"
            s.(names{c}) = num;
        else
            s.(names{c}) = raw;
        end
    end
end

function s = fmtField(v)
    % quote character kept in a variable for readability
    q = '"';
    if isstring(v) || ischar(v)
        s = char(v);
        s = strrep(strrep(s, sprintf('\n'), ' '), sprintf('\r'), ' ');
        if contains(s, ',') || contains(s, q)
            s = [q, strrep(s, q, [q q]), q];
        end
    elseif isempty(v) || ~isfinite(v)
        s = 'NaN';
    elseif v == round(v) && abs(v) < 1e12
        s = sprintf('%d', round(v));
    else
        s = sprintf('%.6f', v);
    end
end

function v = getf(s, f, dflt)
    if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
        v = s.(f);
    else
        v = dflt;
    end
end
