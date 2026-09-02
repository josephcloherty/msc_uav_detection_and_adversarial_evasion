function R = report_util()
%REPORT_UTIL Report-figure helpers: tables drawn as figures, and a key-results log.
%
%   R = report_util() returns a struct of function handles. Every reporting block in
%   Phases 6, 7 and 8 uses these, so one change to the styling changes every figure.
%
%     R.tableFigure(T, file, opts)   draw a MATLAB table as a PNG at 300 dpi, plus .fig
%     R.saveFig(fig, file)           write any figure at 300 dpi on white, plus .fig
%     R.styleAxes(ax)                one axes style for every plot
%     R.palette()                    categorical colours, consistent across phases
%     R.logNew(file, title)          start a key-results text file, overwriting it
%     R.logSection(file, head, txt)  append a headed block of lines
%     R.logTable(file, T, maxRows)   append a fixed-width rendering of a table
%     R.fmtCI(v, lo, hi, dp)         "0.812 [0.744, 0.869]"
%     R.pmSD(v, sd, dp)              "0.812 +/- 0.031"
%
%   tableFigure exists because a result read off a console is not a result anybody can
%   put in a report. Anything worth quoting is drawn instead, exported at print
%   resolution, and dropped straight into the document. Keep tables short: a figure of
%   thirty rows is a spreadsheet, not an exhibit.
%
%   Every figure is written twice: a PNG for the report and a MATLAB .fig of the same
%   name beside it. Open the .fig when a label needs rewording, a legend needs moving or
%   a title needs shortening to fit a column, then export the PNG again from there. The
%   .fig is briefly made visible before saving, because a figure saved while invisible
%   reopens invisible and looks like it failed to load.
%
%   opts fields, all optional:
%     Title      char or string, drawn bold above the table
%     Note       string array, one short line each, drawn small underneath
%     Highlight  logical, one per row; highlighted rows are shaded and bold
%     FontSize   default 10
%     Align      char row vector, one of l/c/r per column; default is numeric
%                columns right and everything else left

R = struct();
R.tableFigure = @tableFigure;
R.saveFig     = @saveFig;
R.styleAxes   = @styleAxes;
R.palette     = @palette;
R.logNew      = @logNew;
R.logSection  = @logSection;
R.logTable    = @logTable;
R.fmtCI       = @fmtCI;
R.pmSD        = @pmSD;
R.ensureDir   = @ensureDir;
end


%% ---- draw a table as a figure --------------------------------------------------
function tableFigure(T, outFile, opts)
if nargin < 3, opts = struct(); end
opts = setdef(opts, 'Title',    '');
opts = setdef(opts, 'Note',     strings(0, 1));
opts = setdef(opts, 'FontSize', 10);
opts = setdef(opts, 'Align',    '');

hdr = T.Properties.VariableNames;
nR  = height(T);
nC  = numel(hdr);
assert(nR > 0, 'report_util:emptyTable', 'No rows to draw for %s.', outFile);
if ~isfield(opts, 'Highlight') || isempty(opts.Highlight)
    opts.Highlight = false(nR, 1);
end
opts.Highlight = logical(opts.Highlight(:));

% --- every cell to text ---
S     = strings(nR, nC);
isNum = false(1, nC);
for j = 1:nC
    col = T.(hdr{j});
    if islogical(col)
        s = repmat("no", nR, 1);
        s(col) = "yes";
        S(:, j) = s;
    elseif isnumeric(col)
        isNum(j) = true;
        S(:, j)  = fmtNumCol(col);
    elseif iscategorical(col)
        S(:, j) = string(col);
    elseif iscell(col)
        S(:, j) = string(col);
    else
        S(:, j) = string(col);
    end
end
S(ismissing(S)) = "-";
S(strcmpi(S, "NaN")) = "-";

hdrTxt = strrep(string(hdr), '_', ' ');

if isempty(opts.Align)
    al = repmat('r', 1, nC);
    al(~isNum) = 'l';
else
    al = char(opts.Align);
    assert(numel(al) == nC, 'report_util:alignLength', ...
        'Align has %d entries for %d columns.', numel(al), nC);
end

% --- geometry, in pixels, then converted to axes fractions ---
fs = opts.FontSize;
w  = zeros(1, nC);
for j = 1:nC
    w(j) = double(max([strlength(hdrTxt(j)); strlength(S(:, j))]));
end
w = w + 3.2;                                  % breathing room, in characters

noteLines = string(opts.Note);
noteLines = noteLines(strlength(noteLines) > 0);

chPx   = 0.60 * fs;
tblW   = sum(w) * chPx;
rowH   = 1.85 * fs;
noteFs = max(6, fs - 2);
noteW  = 0;
if ~isempty(noteLines)
    noteW = double(max(strlength(noteLines))) * 0.58 * noteFs;
end
headH  = 2.35 * fs;
titleH = 0;
if strlength(string(opts.Title)) > 0, titleH = 2.9 * fs; end
noteH = numel(noteLines) * 1.75 * fs;
if noteH > 0, noteH = noteH + 0.5 * fs; end

marginX = 20;
marginY = 14;
% The figure is as wide as the wider of the table and its longest footnote, so a note
% that runs past the last column is not clipped at the edge.
figW = max([360, tblW + 2 * marginX, noteW + 2 * marginX]);
figH = titleH + headH + nR * rowH + noteH + 2 * marginY;

fig = figure('Visible', 'off', 'Color', 'w', 'Units', 'pixels', ...
             'Position', [100 100 round(figW) round(figH)]);
ax = axes('Parent', fig, 'Units', 'normalized', 'Position', [0 0 1 1], ...
          'XLim', [0 1], 'YLim', [0 1]);
axis(ax, 'off'); hold(ax, 'on');

% The table keeps its natural width and sits left; only the notes use the full span.
x0 = marginX / figW;
x1 = x0 + tblW / figW;
xe = x0 + (x1 - x0) * [0, cumsum(w) / sum(w)];

y = 1 - marginY / figH;

if titleH > 0
    text(ax, x0, y - 0.9 * fs / figH, string(opts.Title), 'FontName', 'Helvetica', ...
        'FontSize', fs + 2, 'FontWeight', 'bold', 'Color', [0 0 0], ...
        'VerticalAlignment', 'middle', 'Interpreter', 'none', 'Tag', 'keepColor');
    y = y - titleH / figH;
end

% --- header band ---
hTop = y;
hBot = y - headH / figH;
rectangle('Parent', ax, 'Position', [x0, hBot, x1 - x0, hTop - hBot], ...
          'FaceColor', [0.16 0.20 0.26], 'EdgeColor', 'none');
for j = 1:nC
    placeText(ax, xe(j), xe(j + 1), (hTop + hBot) / 2, hdrTxt(j), al(j), fs, ...
              [1 1 1], 'bold', figW);
end
y = hBot;

% --- body ---
for i = 1:nR
    rTop = y;
    rBot = y - rowH / figH;
    wt = 'normal';
    if opts.Highlight(i)
        rectangle('Parent', ax, 'Position', [x0, rBot, x1 - x0, rTop - rBot], ...
                  'FaceColor', [1.00 0.93 0.76], 'EdgeColor', 'none');
        wt = 'bold';
    elseif mod(i, 2) == 0
        rectangle('Parent', ax, 'Position', [x0, rBot, x1 - x0, rTop - rBot], ...
                  'FaceColor', [0.945 0.953 0.965], 'EdgeColor', 'none');
    end
    for j = 1:nC
        placeText(ax, xe(j), xe(j + 1), (rTop + rBot) / 2, S(i, j), al(j), fs, ...
                  [0.10 0.10 0.10], wt, figW);
    end
    y = rBot;
end
plot(ax, [x0 x1], [y y], '-', 'Color', [0.16 0.20 0.26], 'LineWidth', 1);

% --- notes ---
y = y - 0.45 * fs / figH;
for k = 1:numel(noteLines)
    y = y - 1.75 * fs / figH;
    text(ax, x0, y, noteLines(k), 'FontName', 'Helvetica', 'FontSize', noteFs, ...
        'Color', [0.32 0.34 0.38], 'VerticalAlignment', 'middle', 'Interpreter', 'none', ...
        'Tag', 'keepColor');
end

forceLightTheme(fig);
ensureDir(fileparts(outFile));
exportgraphics(fig, outFile, 'Resolution', 300, 'BackgroundColor', 'white');
saveEditable(fig, outFile);
close(fig);
fprintf('Wrote %s (+ .fig)\n', outFile);
end


function placeText(ax, xa, xb, y, str, al, fs, col, wt, figW)
pad = 7 / figW;
switch al
    case 'r', xp = xb - pad;      ha = 'right';
    case 'c', xp = (xa + xb) / 2; ha = 'center';
    otherwise, xp = xa + pad;     ha = 'left';
end
text(ax, xp, y, str, 'FontName', 'Helvetica', 'FontSize', fs, 'Color', col, ...
    'FontWeight', wt, 'HorizontalAlignment', ha, 'VerticalAlignment', 'middle', ...
    'Interpreter', 'none', 'Tag', 'keepColor');
end


function s = fmtNumCol(v)
%FMTNUMCOL One format for a whole column, chosen from its own magnitude.
v = double(v(:));
n = numel(v);
s = repmat("-", n, 1);
f = v(isfinite(v));
if isempty(f), return; end

if all(abs(f - round(f)) < 1e-9) && max(abs(f)) < 1e6
    fmt = '%d';
    v   = round(v);
else
    m = max(abs(f));
    if m < 1e-3 || m >= 1e5
        fmt = '%.2e';
    elseif m < 1
        fmt = '%.4f';
    elseif m < 100
        fmt = '%.3f';
    else
        fmt = '%.1f';
    end
end
for i = 1:n
    if isfinite(v(i))
        s(i) = string(sprintf(fmt, v(i)));
    end
end
end


%% ---- plot styling --------------------------------------------------------------
function saveFig(fig, file)
forceLightTheme(fig);
ensureDir(fileparts(file));
exportgraphics(fig, file, 'Resolution', 300, 'BackgroundColor', 'white');
saveEditable(fig, file);
fprintf('Wrote %s (+ .fig)\n', file);
end


function saveEditable(fig, file)
%SAVEEDITABLE Write the editable MATLAB figure beside the exported PNG.
%
%   The PNG is what goes in the report. The .fig is what you open when a title is too
%   long for the column, a legend sits over a line, or a label needs rewording after a
%   supervisor reads it. Edit there and export again rather than rerunning the stage,
%   which for Phase 8 means rescoring the whole hold-out.
%
%   The figure is made visible for the save and put back afterwards. openfig honours the
%   visibility stored in the file, so a .fig written while invisible reopens invisible
%   and reads as a failed load. The window flashes up briefly during a batch run; that
%   is the cost of the file being usable when you come back to it.

[d, n] = fileparts(file);
figFile = fullfile(d, [n '.fig']);
was = get(fig, 'Visible');
try
    set(fig, 'Visible', 'on');
    savefig(fig, figFile, 'compact');
catch err
    warning('report_util:figSaveFailed', ...
        'Wrote the PNG but not %s: %s', figFile, err.message);
end
try
    set(fig, 'Visible', was);
catch
end
end


function forceLightTheme(fig)
%FORCELIGHTTHEME White canvas, black text, Helvetica, whatever theme MATLAB is in.
%
%   MATLAB R2025a introduced figure themes, and a figure built while the dark theme is
%   active exports with a black axes background and pale grey text however the figure
%   colour is set. A report figure has to be legible on white paper, so the theme is
%   undone here, once, rather than at thirty call sites.
%
%   Text drawn deliberately light on a dark mark, such as a value printed inside a dark
%   heatmap cell or a table header on its navy band, carries the tag 'keepColor' and is
%   left alone. Text that is already dark is also left alone, so the grey footnotes
%   under a table survive. Everything else is set to black.

try
    set(fig, 'Theme', 'light');            % R2025a and later; older releases have none
catch
end
set(fig, 'Color', 'w');

ink = [0 0 0];

ax = findall(fig, 'Type', 'axes');
for k = 1:numel(ax)
    a = ax(k);
    set(a, 'Color', 'w', 'XColor', ink, 'YColor', ink, 'ZColor', ink, ...
           'GridColor', [0.15 0.15 0.15], 'MinorGridColor', [0.30 0.30 0.30], ...
           'FontName', 'Helvetica');
    set([a.Title, a.XLabel, a.YLabel, a.ZLabel], 'Color', ink, 'FontName', 'Helvetica');
end

lg = findall(fig, 'Type', 'legend');
for k = 1:numel(lg)
    set(lg(k), 'TextColor', ink, 'FontName', 'Helvetica');
    if strcmp(lg(k).Box, 'on')
        set(lg(k), 'Color', 'w', 'EdgeColor', [0.55 0.55 0.55]);
    end
end

cb = findall(fig, 'Type', 'colorbar');
for k = 1:numel(cb)
    set(cb(k), 'Color', ink, 'FontName', 'Helvetica');
    try
        set(cb(k).Label, 'Color', ink, 'FontName', 'Helvetica');
    catch
    end
end

tls = findall(fig, 'Type', 'tiledlayout');
for k = 1:numel(tls)
    try
        set(tls(k).Title, 'Color', ink, 'FontName', 'Helvetica');
    catch
    end
    try
        set(tls(k).Subtitle, 'Color', ink, 'FontName', 'Helvetica');
    catch
    end
end

tx = findall(fig, 'Type', 'text');
for k = 1:numel(tx)
    if strcmp(tx(k).Tag, 'keepColor'), continue; end
    set(tx(k), 'FontName', 'Helvetica');
    c = tx(k).Color;
    if isnumeric(c) && numel(c) == 3 && mean(c) >= 0.5
        set(tx(k), 'Color', ink);
    end
end
end


function styleAxes(ax)
set(ax, 'FontName', 'Helvetica', 'FontSize', 10, 'Box', 'off', ...
        'TickDir', 'out', 'LineWidth', 0.75, 'Layer', 'top', ...
        'Color', 'w', 'XColor', [0 0 0], 'YColor', [0 0 0]);
grid(ax, 'on');
ax.GridColor = [0.15 0.15 0.15];
ax.GridAlpha = 0.15;
end


function m = palette(n)
%PALETTE Colour-blind-safe categorical colours, in a fixed order.
base = [0.35 0.35 0.35;      % grey, the baseline or reference series
        0.00 0.45 0.70;      % blue
        0.85 0.37 0.01;      % orange
        0.46 0.16 0.51;      % purple
        0.10 0.60 0.35;      % green
        0.80 0.16 0.24;      % red
        0.35 0.55 0.75];     % pale blue
if nargin < 1 || isempty(n)
    m = base;
else
    m = base(mod((0:n - 1)', size(base, 1)) + 1, :);
end
end


%% ---- key-results log -----------------------------------------------------------
function logNew(file, titleLine)
%LOGNEW Start the phase's key-results file, replacing anything already there.
ensureDir(fileparts(file));
fid = fopen(file, 'w');
assert(fid > 0, 'report_util:logOpen', 'Cannot open %s for writing.', file);
t = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
fprintf(fid, '%s\n%s\n', titleLine, repmat('=', 1, numel(char(titleLine))));
fprintf(fid, 'Written %s\n', t);
fclose(fid);
end


function logSection(file, heading, lines)
%LOGSECTION Append a headed block. lines is a string array, one entry per line.
ensureDir(fileparts(file));
fid = fopen(file, 'a');
assert(fid > 0, 'report_util:logOpen', 'Cannot open %s for appending.', file);
fprintf(fid, '\n%s\n%s\n', heading, repmat('-', 1, numel(char(heading))));
lines = string(lines);
lines = lines(strlength(lines) > 0);
for k = 1:numel(lines)
    fprintf(fid, '  %s\n', lines(k));
end
fclose(fid);
end


function logTable(file, T, maxRows)
%LOGTABLE Append a table as fixed-width text, so the numbers are greppable later.
if nargin < 3 || isempty(maxRows), maxRows = 20; end
if height(T) > maxRows, T = T(1:maxRows, :); end

hdr = strrep(string(T.Properties.VariableNames), '_', ' ');
nR  = height(T);
nC  = numel(hdr);
S   = strings(nR, nC);
for j = 1:nC
    col = T.(T.Properties.VariableNames{j});
    if islogical(col)
        s = repmat("no", nR, 1); s(col) = "yes"; S(:, j) = s;
    elseif isnumeric(col)
        S(:, j) = fmtNumCol(col);
    else
        S(:, j) = string(col);
    end
end
S(ismissing(S)) = "-";

w = zeros(1, nC);
for j = 1:nC
    w(j) = double(max([strlength(hdr(j)); strlength(S(:, j))])) + 2;
end

colFmt = cell(1, nC);
for j = 1:nC
    colFmt{j} = sprintf('%%-%ds', w(j));      % MATLAB fprintf has no '*' field width
end

fid = fopen(file, 'a');
assert(fid > 0, 'report_util:logOpen', 'Cannot open %s for appending.', file);
fprintf(fid, '  ');
for j = 1:nC, fprintf(fid, colFmt{j}, hdr(j)); end
fprintf(fid, '\n  %s\n', repmat('-', 1, sum(w)));
for i = 1:nR
    fprintf(fid, '  ');
    for j = 1:nC, fprintf(fid, colFmt{j}, S(i, j)); end
    fprintf(fid, '\n');
end
fclose(fid);
end


%% ---- small formatters ----------------------------------------------------------
function s = fmtCI(v, lo, hi, dp)
if nargin < 4 || isempty(dp), dp = 3; end
if isnan(lo) || isnan(hi)
    s = string(sprintf('%.*f', dp, v));
else
    s = string(sprintf('%.*f [%.*f, %.*f]', dp, v, dp, lo, dp, hi));
end
end


function s = pmSD(v, sd, dp)
if nargin < 3 || isempty(dp), dp = 3; end
s = string(sprintf('%.*f +/- %.*f', dp, v, dp, sd));
end


function ensureDir(d)
if ~isempty(d) && ~isfolder(d), mkdir(d); end
end


function opts = setdef(opts, name, value)
%SETDEF Fill one option with its default when the caller left it out.
if ~isfield(opts, name)
    opts.(name) = value;
end
end
