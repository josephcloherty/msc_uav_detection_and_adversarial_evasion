classdef phase5b_Progress < handle
%phase5b_Progress Client-side batch progress reporter.
%
%   The runs execute on parallel workers with no display and many are in
%   flight at once, so the readout lives on the CLIENT and shows each run as
%   well as the aggregate.
%
%   Each worker sends two kinds of message through a parallel.pool.DataQueue:
%     struct('kind',"progress",'run',i,'frac',f,'wall',w)  periodic, f is
%                 that run's simulated-time fraction in [0 1] and w its own
%                 wall time so far
%     struct('kind',"done",'run',i,'status',s,'wall',w)    once, s is "ok",
%                 "failed" or "skipped"
%
%   ESTIMATED TIME REMAINING
%   Wall time is measured on the worker, so a run's rate is its own seconds
%   rather than a client clock that includes queue latency. Each message
%   updates a per-run EWMA of fraction per second, so a run that slows as its
%   logs grow is followed rather than averaged over its history. A run that
%   has not reported yet is estimated from the cost model, rescaled by what
%   the reporting runs are actually costing. The batch is one run per worker
%   with no queue, so the batch ETA is the largest of the per-run ETAs.
%
%   DISPLAY MODES
%     "perrun"  one horizontal bar per run, coloured by state, aggregate on a
%               header line. Default.
%     "single"  one waitbar carrying the aggregate only. Used above
%               cfg.progress.maxBars, where one bar per run is unreadable.
%     "text"    throttled printing, used when there is no desktop.
%
%   Overall progress is the mean simulated-time fraction over the runs being
%   executed, not a count of completed runs, so a batch of long runs does not
%   sit at zero per cent until the first worker finishes. Skipped runs are
%   excluded from the denominator.
%
%   Usage (phase5b_RunBatch):
%       prog = phase5b_Progress(labels, cfg.progress);
%       prog.markSkipped(~todo);
%       guard = onCleanup(@() prog.close());
%       q = parallel.pool.DataQueue;
%       afterEach(q, @(m) prog.update(m));
%
%   afterEach callbacks are serviced while the client waits inside parfor.
%
%   The configuration struct takes enable, useWaitbar, perRunBars, maxBars,
%   minRedraw_s, rateAlpha and statusFile.

    properties
        nRuns                       % number of enumerated runs
        labels          string      % 1 x nRuns, e.g. "UMa seed 7"
        frac            double      % 1 x nRuns, simulated-time fraction
        state           string      % pending | running | ok | failed | skipped
        skipped         logical     % excluded from the progress denominator
        startTic                    % batch wall clock
        mode            string = "text"   % perrun | single | text
        enabled         = true      % false: run lines only, no live display
        minRedraw       = 0.5       % s, throttle between redraws
        lastRedrawTic
        lastTextPct     = -1        % last percentage printed in text mode
        doneCount       = 0

        % ---- cost/ETA state, all 1 x nRuns ----
        priorWall       double      % cost-model estimate per run, s
        selfWall        double      % last wall time reported by the worker
        lastFrac        double      % fraction at that wall time
        rate            double      % EWMA of fraction per worker-second
        ratio           double      % measured cost / prior cost, per run
        ratioW          double      % confidence weight for that ratio
        rateAlpha       = 0.35      % EWMA weight on the newest sample
        numWorkers      = 1         % pool size, reported in the header
        lastRowText     string      % last string actually set on each row
        statusFile      = ""        % plain-text status board, rewritten live
    end

    properties (Access = private)
        fig    = []                 % uifigure, "perrun" mode
        ax     = []                 % uiaxes holding the bars
        barH   = []                 % Bar object: the filled progress bars
        trackH = []                 % Bar object: full-width row backgrounds
        txt    = []                 % one text object per run, the row label
        hdr    = []                 % header uilabel
        bar    = []                 % classic waitbar, "single" mode
    end

    properties (Constant, Access = private)
        % Failure is the only saturated colour.
        COL_PENDING = [0.55 0.57 0.62];
        COL_RUNNING = [0.20 0.42 0.72];
        COL_OK      = [0.24 0.60 0.36];
        COL_FAILED  = [0.78 0.20 0.20];
        COL_SKIPPED = [0.42 0.44 0.48];
        COL_SALVAGED= [0.86 0.60 0.20];   % amber: partial rows kept
        COL_TRACK   = [0.30 0.31 0.34];   % empty part of every row

        % Text column width in bar-length units: the axes runs from
        % -LABELW to 1 and the row text lives in the negative region.
        LABELW = 0.72;
    end

    methods
        function obj = phase5b_Progress(labels, pcfg, opts)
            %phase5b_Progress OPTS carries the cost-model prior and pool size.
            %   opts.priorWall_s  1 x nRuns expected wall time, from
            %                     phase5b_CostModel; NaN falls back to
            %                     extrapolating the mean percentage.
            %   opts.numWorkers   pool size, reported in the header.
            obj.labels  = string(labels(:))';
            obj.nRuns   = numel(obj.labels);
            obj.frac    = zeros(1, obj.nRuns);
            obj.state   = repmat("pending", 1, obj.nRuns);
            obj.skipped = false(1, obj.nRuns);
            obj.startTic = tic;
            obj.lastRedrawTic = tic;

            obj.priorWall = nan(1, obj.nRuns);
            obj.selfWall  = zeros(1, obj.nRuns);
            obj.lastFrac  = zeros(1, obj.nRuns);
            obj.rate      = zeros(1, obj.nRuns);
            obj.ratio     = nan(1, obj.nRuns);
            obj.ratioW    = zeros(1, obj.nRuns);

            useWaitbar = true; perRun = true; maxBars = 40;
            if nargin >= 2 && ~isempty(pcfg)
                if isfield(pcfg, 'enable'),      obj.enabled   = pcfg.enable;      end
                if isfield(pcfg, 'useWaitbar'),  useWaitbar    = pcfg.useWaitbar;  end
                if isfield(pcfg, 'perRunBars'),  perRun        = pcfg.perRunBars;  end
                if isfield(pcfg, 'maxBars'),     maxBars       = pcfg.maxBars;     end
                if isfield(pcfg, 'minRedraw_s'), obj.minRedraw = pcfg.minRedraw_s; end
                if isfield(pcfg, 'rateAlpha'),   obj.rateAlpha = pcfg.rateAlpha;   end
                if isfield(pcfg, 'statusFile'),  obj.statusFile = string(pcfg.statusFile); end
            end
            if nargin >= 3 && ~isempty(opts)
                if isfield(opts, 'priorWall_s') && ~isempty(opts.priorWall_s)
                    w = double(opts.priorWall_s(:))';
                    if numel(w) == obj.nRuns, obj.priorWall = w; end
                end
                if isfield(opts, 'numWorkers') && ~isempty(opts.numWorkers)
                    obj.numWorkers = max(round(opts.numWorkers), 1);
                end
            end

            if ~obj.enabled || ~usejava('desktop')
                obj.mode = "text";
            elseif perRun && obj.nRuns <= maxBars
                obj.mode = "perrun";
            elseif useWaitbar
                obj.mode = "single";
            else
                obj.mode = "text";
            end

            switch obj.mode
                case "perrun"
                    % uiaxes and barh behaviour has changed across
                    % releases, so fall back rather than fail the batch.
                    try
                        obj.buildPerRunWindow();
                    catch err
                        warning('phase5b_Progress:perRunFailed', ...
                            ['Per-run progress window could not be built ' ...
                             '(%s). Falling back to a single aggregate ' ...
                             'bar.'], err.message);
                        if useWaitbar
                            obj.mode = "single";
                            obj.bar = waitbar(0, 'Starting batch...', ...
                                'Name', 'Phase 5b batch');
                        else
                            obj.mode = "text";
                        end
                    end
                case "single"
                    obj.bar = waitbar(0, 'Starting batch...', ...
                        'Name', 'Phase 5b batch');
            end
            obj.draw(true);
            drawnow;   % force the window to paint before parfor blocks the client
        end

        function markSkipped(obj, mask)
            %markSkipped Exclude runs that are already on disk.
            mask = logical(mask(:))';
            obj.skipped(mask) = true;
            obj.state(mask)   = "skipped";
            obj.frac(mask)    = 1;
            obj.draw(true);
        end

        function update(obj, msg)
            %update Handle one message from a worker.
            switch string(msg.kind)
                case "progress"
                    % Guards against out-of-order delivery.
                    i = msg.run;
                    obj.frac(i)  = max(obj.frac(i), msg.frac);
                    obj.state(i) = "running";
                    obj.observe(i, msg);
                    obj.draw(false);
                case "done"
                    obj.frac(msg.run)  = 1;
                    obj.state(msg.run) = string(msg.status);
                    obj.doneCount = obj.doneCount + 1;
                    obj.closeOut(msg);
                    obj.printRunLine(msg.run);
                    obj.draw(true);
                otherwise
                    % Ignored: a reporter must never take down a batch.
            end
        end

        function close(obj)
            %close Tear down whichever display was built.
            if ~isempty(obj.fig) && isvalid(obj.fig), delete(obj.fig); end
            if ~isempty(obj.bar) && isvalid(obj.bar), delete(obj.bar); end
            obj.fig = []; obj.bar = [];
        end
    end

    methods (Access = private)
        function buildPerRunWindow(obj)
            %buildPerRunWindow One labelled row per run, in one axes.
            %   Row text is one text object per run, not a Y tick label:
            %   updating bar data puts the ruler back into automatic mode and
            %   MATLAB then recycles tick labels onto whatever ticks remain.
            %   Each row is drawn twice, a full-width track and the bar on top,
            %   so a run at zero per cent is a visible row rather than a gap.
            n = obj.nRuns;
            % Sized from the run count and clamped to the screen.
            rowPx = 26;
            scr = get(0, 'ScreenSize');
            hMax = max(scr(4) - 140, 420);
            h = min(150 + rowPx*n, hMax);
            fs = 10;
            if n > 20, fs = 9; end
            if n > 30, fs = 8; end

            obj.fig = uifigure('Name', 'Phase 5b batch', ...
                'Position', [80 60 1000 h]);
            g = uigridlayout(obj.fig, [2 1]);
            g.RowHeight = {28, '1x'};
            g.Padding = [8 8 8 8];

            obj.hdr = uilabel(g, 'Text', 'Starting batch...', ...
                'FontName', 'Consolas', 'FontSize', 11);
            obj.hdr.Layout.Row = 1;

            obj.ax = uiaxes(g);
            obj.ax.Layout.Row = 2;
            hold(obj.ax, 'on');
            obj.trackH = barh(obj.ax, 1:n, ones(1, n), 0.74, ...
                'FaceColor', obj.COL_TRACK, 'EdgeColor', 'none');
            obj.barH = barh(obj.ax, 1:n, zeros(1, n), 0.74, ...
                'FaceColor', 'flat', 'EdgeColor', 'none');
            obj.barH.CData = repmat(obj.COL_PENDING, n, 1);
            hold(obj.ax, 'off');

            obj.ax.YDir  = 'reverse';        % run 1 at the top
            obj.ax.XLim  = [-obj.LABELW 1];  % negative region holds the text
            obj.ax.YLim  = [0.5 n+0.5];
            obj.ax.YTick = [];               % no tick labels at all
            obj.ax.XTick = 0:0.25:1;
            obj.ax.XTickLabel = {'0','25','50','75','100%'};
            obj.ax.FontName = 'Consolas';
            obj.ax.FontSize = fs;
            obj.ax.Box = 'off';
            obj.ax.XGrid = 'on';

            % Colour from the ruler, so rows read under either desktop theme.
            col = obj.ax.XColor;
            obj.txt = gobjects(1, n);
            for i = 1:n
                obj.txt(i) = text(obj.ax, -obj.LABELW + 0.012, i, '', ...
                    'FontName', 'Consolas', 'FontSize', fs, 'Color', col, ...
                    'VerticalAlignment', 'middle', 'Interpreter', 'none', ...
                    'Clipping', 'off');
            end
            obj.refreshRowText();
        end

        function refreshRowText(obj)
            %refreshRowText Per-run row: name, percentage, state, own ETA.
            %   Only rows whose text changed are written. Every property set
            %   on a uifigure is a message into MATLAB's Chromium process,
            %   which was killed out of memory during the 6 August batch.
            if isempty(obj.txt), return; end
            if numel(obj.lastRowText) ~= obj.nRuns
                obj.lastRowText = strings(1, obj.nRuns);
            end
            for i = 1:obj.nRuns
                if ~isgraphics(obj.txt(i)), continue; end
                s = obj.rowText(i);
                if s == obj.lastRowText(i), continue; end
                obj.txt(i).String = s;
                obj.lastRowText(i) = s;
            end
        end

        function s = rowText(obj, i)
            %rowText One row of the status board, used by the window and file.
            s = string(sprintf('%-13s %3.0f%%  %-8s %s', obj.labels(i), ...
                100*obj.frac(i), obj.stateWord(i), obj.runEtaText(i)));
        end

        function writeStatusFile(obj, msg)
            %writeStatusFile The whole board as plain text, overwritten in place.
            %   The window's content without the window, so a headless batch
            %   is still watchable. Failure is ignored on purpose.
            if strlength(obj.statusFile) == 0, return; end
            try
                fid = fopen(char(obj.statusFile), 'w');
                if fid < 0, return; end
                fprintf(fid, 'Phase 5b batch, %s\n%s\n\n', ...
                    char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), msg);
                for i = 1:obj.nRuns
                    fprintf(fid, '%s\n', obj.rowText(i));
                end
                fclose(fid);
            catch
            end
        end

        function w = stateWord(obj, i)
            %stateWord The word for a run's state.
            %   "pending" reads as "starting": every run holds a worker from
            %   the outset, so it is early rather than queued. A row that sits
            %   on "starting" is a run in trouble.
            switch obj.state(i)
                case "pending",  w = "starting";
                case "running",  w = "running";
                case "ok",       w = "done";
                case "failed",   w = "FAILED";
                case "skipped",  w = "on disk";
                case "salvaged", w = "salvaged";
                otherwise,       w = obj.state(i);
            end
        end

        function observe(obj, i, msg)
            %observe Fold one progress report into this run's rate estimate.
            %   Differenced against the previous report rather than averaged,
            %   so a run that slows as its logs grow is tracked.
            if ~isfield(msg, 'wall'), return; end
            w = double(msg.wall);
            if ~isfinite(w) || w <= 0, return; end
            f = obj.frac(i);
            dF = f - obj.lastFrac(i);
            dW = w - obj.selfWall(i);
            if obj.selfWall(i) > 0 && dW > 1e-6 && dF > 0
                r = dF / dW;
                if obj.rate(i) > 0
                    obj.rate(i) = (1 - obj.rateAlpha)*obj.rate(i) + ...
                        obj.rateAlpha*r;
                else
                    obj.rate(i) = r;
                end
            elseif f > 0 && obj.rate(i) <= 0
                obj.rate(i) = f / w;
            end
            obj.selfWall(i) = w;
            obj.lastFrac(i) = f;

            % Weighted by fraction completed, so an early guess counts little.
            if obj.rate(i) > 0 && isfinite(obj.priorWall(i)) && obj.priorWall(i) > 0
                obj.ratio(i)  = (1/obj.rate(i)) / obj.priorWall(i);
                obj.ratioW(i) = max(f, 0);
            end
        end

        function closeOut(obj, msg)
            %closeOut A finished run's measured cost is the best calibration.
            i = msg.run;
            if ~isfield(msg, 'wall'), return; end
            w = double(msg.wall);
            if ~isfinite(w) || w <= 0, return; end
            obj.selfWall(i) = w;
            obj.rate(i) = 1/w;
            if isfinite(obj.priorWall(i)) && obj.priorWall(i) > 0
                obj.ratio(i)  = w / obj.priorWall(i);
                obj.ratioW(i) = 1;      % measured to completion
            end
        end

        function s = calScale(obj)
            %calScale Weighted correction from the cost model to this machine.
            sel = isfinite(obj.ratio) & obj.ratioW > 0;
            if ~any(sel)
                s = 1;
            else
                s = sum(obj.ratio(sel) .* obj.ratioW(sel)) / sum(obj.ratioW(sel));
            end
            if ~isfinite(s) || s <= 0, s = 1; end
        end

        function w = expectedWall(obj, i)
            %expectedWall Recalibrated cost-model estimate for one run.
            %   With no model, falls back to the median peer cost in this
            %   batch; runs differ in UE count by only about 1.5x.
            w = obj.priorWall(i) * obj.calScale();
            if isfinite(w) && w > 0, return; end
            peer = obj.rate > 0;
            if any(peer)
                w = median(1 ./ obj.rate(peer));
            else
                w = NaN;
            end
        end

        function e = runEta(obj, i)
            %runEta Seconds remaining for one run: measured rate, else model.
            if obj.skipped(i) || ismember(obj.state(i), ...
                    ["ok" "failed" "skipped" "salvaged"])
                e = 0;
                return;
            end
            if obj.rate(i) > 0
                e = (1 - obj.frac(i)) / obj.rate(i);
            else
                e = obj.expectedWall(i) * (1 - obj.frac(i));
            end
        end

        function t = runEtaText(obj, i)
            %runEtaText What this row says to the right of its state.
            %   "~" marks a cost-model projection rather than a measurement.
            if obj.skipped(i)
                t = "";
                return;
            end
            switch obj.state(i)
                case "ok"
                    t = "in " + obj.compactDur(obj.selfWall(i));
                case {"failed", "salvaged", "skipped"}
                    t = "";
                case "pending"
                    e = obj.expectedWall(i);
                    if ~isfinite(e) || e <= 0
                        t = "ETA --";
                    else
                        t = "ETA ~" + obj.compactDur(e);
                    end
                otherwise
                    e = obj.runEta(i);
                    if ~isfinite(e)
                        t = "ETA --";
                    else
                        t = "ETA " + obj.compactDur(e);
                    end
            end
        end

        function C = stateColours(obj)
            C = repmat(obj.COL_PENDING, obj.nRuns, 1);
            C(obj.state == "running", :) = repmat(obj.COL_RUNNING, sum(obj.state == "running"), 1);
            C(obj.state == "ok", :)      = repmat(obj.COL_OK,      sum(obj.state == "ok"), 1);
            C(obj.state == "failed", :)  = repmat(obj.COL_FAILED,  sum(obj.state == "failed"), 1);
            C(obj.state == "skipped", :) = repmat(obj.COL_SKIPPED, sum(obj.state == "skipped"), 1);
            C(obj.state == "salvaged", :)= repmat(obj.COL_SALVAGED, sum(obj.state == "salvaged"), 1);
        end

        function printRunLine(obj, i)
            active = ~obj.skipped;
            if obj.selfWall(i) > 0
                own = sprintf('%s run, ', fmtDuration(obj.selfWall(i)));
            else
                own = '';
            end
            nRun = sum(active & ismember(obj.state, ["pending" "running"]));
            fprintf('[%3d/%3d] %-22s %-8s (%s%s elapsed, %d still running, batch ETA %s)\n', ...
                obj.doneCount, sum(active), obj.labels(i), obj.state(i), ...
                own, fmtDuration(toc(obj.startTic)), nRun, ...
                fmtDuration(obj.eta()));
        end

        function e = eta(obj)
            %eta Batch seconds remaining: the slowest run still going.
            %   Every run holds its own worker from the start, so the batch
            %   ends when its slowest run ends. naiveEta is the fallback for
            %   when nothing has reported and no cost model was supplied.
            active = ~obj.skipped;
            if ~any(active)
                e = 0;
                return;
            end

            unfinished = active & ismember(obj.state, ["pending" "running"]);
            if ~any(unfinished)
                e = 0;
                return;
            end

            haveModel = any(isfinite(obj.priorWall(active)));
            reported  = any(active & obj.rate > 0);
            if ~reported && ~haveModel
                e = obj.naiveEta();
                return;
            end

            rem = arrayfun(@(i) obj.runEta(i), find(unfinished));
            rem = rem(isfinite(rem));
            if isempty(rem)
                e = obj.naiveEta();
            else
                e = max(rem);
            end
        end

        function e = naiveEta(obj)
            %naiveEta Mean-percentage extrapolation, the pre-model fallback.
            active = ~obj.skipped;
            elapsed = toc(obj.startTic);
            overall = mean(obj.frac(active));
            if overall <= 0
                e = NaN;                        % nothing to estimate from yet
            else
                e = elapsed/overall - elapsed;
            end
        end

        function s = headline(obj, etaSec)
            %headline The aggregate line: how many runs are in each state.
            %   Counted per state so the numbers always sum to the batch.
            active = ~obj.skipped;
            if any(active)
                overall = mean(obj.frac(active));
            else
                overall = 1;
            end
            if nargin < 2, etaSec = obj.eta(); end
            % Shown once it moves off 1, so a batch outside its projection says so.
            sc = obj.calScale();
            if abs(sc - 1) > 0.05 && any(isfinite(obj.priorWall))
                cal = sprintf('  |  cost x%.2f vs model', sc);
            else
                cal = '';
            end
            nOK = sum(active & ismember(obj.state, ["ok" "salvaged"]));
            nF  = sum(active & obj.state == "failed");
            nR  = sum(active & obj.state == "running");
            nS  = sum(active & obj.state == "pending");
            if nF > 0
                fail = sprintf(', %d failed', nF);
            else
                fail = '';
            end
            s = sprintf(['%d done, %d running, %d starting%s of %d  |  overall ' ...
                '%.1f%%  |  wall %s  |  ETA %s%s'], nOK, nR, nS, fail, ...
                sum(active), 100*overall, obj.compactDur(toc(obj.startTic)), ...
                obj.compactDur(etaSec), cal);
        end

        function draw(obj, force)
            if ~force && toc(obj.lastRedrawTic) < obj.minRedraw
                return;
            end
            obj.lastRedrawTic = tic;

            active = ~obj.skipped;
            if any(active)
                overall = mean(obj.frac(active));
            else
                overall = 1;
            end
            % Once per redraw, so header and rows share one calibration.
            etaSec = obj.eta();
            msg = obj.headline(etaSec);

            % Every mode, including with the display disabled: the only
            % readout that survives losing the desktop.
            obj.writeStatusFile(msg);
            if obj.mode == "text" && ~obj.enabled
                return;              % no live display was asked for
            end

            switch obj.mode
                case "perrun"
                    if isempty(obj.fig) || ~isvalid(obj.fig)
                        return;   % user closed the window; keep running
                    end
                    obj.barH.YData = obj.frac;      % barh: YData is bar length
                    obj.barH.CData = obj.stateColours();
                    % Updating a Bar can put the rulers back into automatic
                    % mode, so the geometry is re-asserted here.
                    obj.ax.YLim  = [0.5 obj.nRuns+0.5];
                    obj.ax.XLim  = [-obj.LABELW 1];
                    obj.ax.YTick = [];
                    obj.refreshRowText();
                    obj.hdr.Text = msg;
                    drawnow limitrate;

                case "single"
                    if ~isempty(obj.bar) && isvalid(obj.bar)
                        waitbar(min(max(overall, 0), 1), obj.bar, msg);
                    end

                case "text"
                    % Only when the percentage moves.
                    pct = floor(100*overall);
                    if pct ~= obj.lastTextPct
                        obj.lastTextPct = pct;
                        fprintf('[%5.1f%%] %s\n', 100*overall, msg);
                    end
            end
        end
    end

    methods (Static, Access = private)
        function s = compactDur(x)
            %compactDur Two significant units, for a readout not a stopwatch.
            %   fmtDuration keeps full precision for the printed record.
            if ~isfinite(x)
                s = "--";
                return;
            end
            x = max(x, 0);
            d = floor(x/86400);
            h = floor(mod(x, 86400)/3600);
            m = floor(mod(x, 3600)/60);
            if d > 0
                s = sprintf('%dd %dh', d, h);
            elseif h > 0
                s = sprintf('%dh %02dm', h, m);
            elseif m > 0
                s = sprintf('%dm', m);
            else
                s = sprintf('%ds', floor(x));
            end
            s = string(s);
        end
    end
end
