classdef phase5_Progress < handle
%phase5_Progress Client-side batch progress reporter (D5.1 support).
%
%   Phase 3 and Phase 4 reported progress from inside the pipeline with a
%   waitbar showing simulated time, wall time and an estimated time
%   remaining. That cannot work for a batch: the runs execute on parallel
%   workers with no display, and there are many of them in flight at
%   once. This class keeps the same readout on the CLIENT and shows it
%   per run as well as in aggregate.
%
%   Each worker sends two kinds of message through a
%   parallel.pool.DataQueue:
%     struct('kind',"progress",'run',i,'frac',f,'wall',w)  periodic, f is
%                                                 that run's simulated-time
%                                                 fraction in [0 1] and w
%                                                 its own wall time so far
%     struct('kind',"done",'run',i,'status',s,'wall',w)    once, s is "ok",
%                                                 "failed" or "skipped"
%
%   ESTIMATED TIME REMAINING
%   The wall time in each message is measured on the worker, so a run's
%   rate is that run's own seconds rather than a client-side clock that
%   includes queue latency. Each message updates a per-run rate, held as an
%   exponentially weighted mean of the recent simulated-fraction-per-second
%   so a run that slows down as its logs grow is followed rather than
%   averaged over its whole history, and the run's own ETA is the remaining
%   fraction at that rate. A run that has not reported yet is estimated
%   from the cost model instead, rescaled by the ratio between what the
%   reporting runs are actually costing and what the model predicted for
%   them; that ratio is recomputed on every message, so the estimate for a
%   run that has not reported yet tracks the machine it is running on. The
%   batch ETA is then simply the largest of the per-run ETAs. The batch is
%   sized to the pool, one run per worker, so every run is in flight from
%   the start and the batch finishes when its slowest run does; there is no
%   queue to schedule and no run whose start time has to be predicted.
%
%   DISPLAY MODES
%     "perrun"  one horizontal bar per run in a single figure, coloured
%               by state, with a header line carrying the aggregate. This
%               is the default and shows exactly which runs are in
%               flight, how far each has got, and which have failed.
%     "single"  one classic waitbar carrying the aggregate only. Used
%               automatically when the batch has more runs than
%               cfg.progress.maxBars, where one bar per run would be
%               unreadable, and selectable directly.
%     "text"    throttled printing, used when there is no desktop.
%
%   Overall progress is the mean simulated-time fraction over the runs
%   being executed, not a count of completed runs. That matters because a
%   batch of long runs would otherwise sit at zero per cent, with no
%   estimated time remaining, until the first worker finished. Runs
%   skipped because their CSV already exists are excluded from the
%   denominator, so resuming a part-finished batch does not report itself
%   as nearly complete before it has done any work.
%
%   Usage (phase5_RunBatch):
%       prog = phase5_Progress(labels, cfg.progress);
%       prog.markSkipped(~todo);
%       guard = onCleanup(@() prog.close());   % closes the window on error too
%       q = parallel.pool.DataQueue;
%       afterEach(q, @(m) prog.update(m));
%
%   afterEach callbacks are serviced while the client waits inside parfor,
%   so the display keeps moving for the whole batch.
%
%   The configuration struct takes enable, useWaitbar, perRunBars,
%   maxBars and minRedraw_s. With enable false the live display is
%   suppressed entirely and only the one-line-per-completed-run record is
%   printed, which is what a log-scraped or headless batch usually wants.

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
        % State colours. Muted enough to read as a status panel rather
        % than a chart, with failure the only saturated colour.
        COL_PENDING = [0.55 0.57 0.62];
        COL_RUNNING = [0.20 0.42 0.72];
        COL_OK      = [0.24 0.60 0.36];
        COL_FAILED  = [0.78 0.20 0.20];
        COL_SKIPPED = [0.42 0.44 0.48];
        COL_SALVAGED= [0.86 0.60 0.20];   % amber: partial rows kept
        COL_TRACK   = [0.30 0.31 0.34];   % empty part of every row

        % Width of the text column, in bar-length units. The axes runs from
        % -LABELW to 1, the bars occupy 0 to 1, and the row text is drawn as
        % text objects in the negative region. Gridlines only appear at the
        % XTick values, which are all >= 0, so the text column stays clean.
        LABELW = 0.72;
    end

    methods
        function obj = phase5_Progress(labels, pcfg, opts)
            %phase5_Progress OPTS carries the cost-model prior and pool size.
            %   opts.priorWall_s  1 x nRuns expected wall time per run, from
            %                     phase5_CostModel. Absent or NaN falls back
            %                     to extrapolating the mean percentage, the
            %                     original behaviour.
            %   opts.numWorkers   pool size. The batch is sized to it, one
            %                     run per worker, so this is only reported.
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
                    % Fall back to the aggregate waitbar rather than
                    % failing the whole batch if the per-run window cannot
                    % be built on this release (uiaxes/barh behaviour has
                    % changed across versions).
                    try
                        obj.buildPerRunWindow();
                    catch err
                        warning('phase5_Progress:perRunFailed', ...
                            ['Per-run progress window could not be built ' ...
                             '(%s). Falling back to a single aggregate ' ...
                             'bar.'], err.message);
                        if useWaitbar
                            obj.mode = "single";
                            obj.bar = waitbar(0, 'Starting batch...', ...
                                'Name', 'Phase 5 batch');
                        else
                            obj.mode = "text";
                        end
                    end
                case "single"
                    obj.bar = waitbar(0, 'Starting batch...', ...
                        'Name', 'Phase 5 batch');
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
                    % max() guards against out-of-order delivery, which
                    % would otherwise make a bar jump backwards.
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
                    % Unknown message kinds are ignored rather than
                    % erroring: a progress reporter must never be able to
                    % take down a batch that is otherwise running fine.
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
            %
            %   WHY THE ROW TEXT IS NOT IN THE Y TICK LABELS
            %   It was, and on a 24-run batch it broke: MATLAB put YTick back
            %   into automatic mode when the bar data was updated, leaving
            %   four ticks, and then recycled the first four of the 24 tick
            %   labels onto them. The window showed four labels reading
            %   "seed 13" to "seed 16" spread down an otherwise blank axis.
            %   Tick labels are a property of the ruler, not of the data, so
            %   the axes is free to renumber them. One text object per run is
            %   not: it has its own position, it cannot be thinned, recycled
            %   or renumbered, and 24 of them cost nothing to update.
            %
            %   Each row is drawn twice: a full-width track so every run is a
            %   visible row even at zero per cent, and the progress bar on top
            %   of it. Without the track a run at zero per cent is an empty
            %   space rather than a row, which
            %   is what made the first window look broken even where it was
            %   working.
            n = obj.nRuns;
            % Sized from the run count and clamped to the screen, so every run
            % gets a row of a legible height rather than n rows squeezed into
            % a fixed window. The font steps down for large batches.
            rowPx = 26;
            scr = get(0, 'ScreenSize');
            hMax = max(scr(4) - 140, 420);
            h = min(150 + rowPx*n, hMax);
            fs = 10;
            if n > 20, fs = 9; end
            if n > 30, fs = 8; end

            obj.fig = uifigure('Name', 'Phase 5 batch', ...
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

            % One text object per row. Colour is taken from the ruler so the
            % rows stay legible under either the light or the dark desktop
            % theme rather than being hard-coded to one of them.
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
            %   Fixed-width fields in a monospaced font, so the four columns
            %   line up down the window. The per-run ETA is the point of the
            %   readout: the batch ends with its slowest run, so a batch
            %   percentage says nothing about when it will finish or which run
            %   is holding it up.
            if isempty(obj.txt), return; end
            for i = 1:obj.nRuns
                if ~isgraphics(obj.txt(i)), continue; end
                obj.txt(i).String = sprintf('%-13s %3.0f%%  %-8s %s', ...
                    obj.labels(i), 100*obj.frac(i), obj.stateWord(i), ...
                    obj.runEtaText(i));
            end
        end

        function w = stateWord(obj, i)
            %stateWord The word for a run's state, in the batch's own terms.
            %   "pending" is what the state machine calls a run that has not
            %   reported yet. Every run has a worker of its own from the
            %   outset, so such a run is starting, not queued: it holds a
            %   worker and is in its opening minutes, before the pipeline has
            %   sent its first simulated-time fraction. A row that sits on
            %   "starting" for longer than that is a run in trouble, which is
            %   worth being able to see.
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
            %   The rate is taken from the change since the previous report
            %   rather than from the run's average, so a run whose per-window
            %   extraction cost grows as its logs grow is tracked instead of
            %   being flattered by its fast opening minutes. The first usable
            %   report has nothing to difference against and seeds the rate
            %   with the average so far.
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

            % Recalibrate the cost model against this run in flight. The
            % weight is the fraction completed, so an early guess counts for
            % little and a run near its end counts for nearly as much as a
            % finished one.
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
            %   With no cost model supplied, a run yet to report is estimated
            %   from what its peers in this batch are actually costing, which
            %   is a far better guess than nothing: the runs differ in UE
            %   count but only by a factor of about 1.5.
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
            %   Every unfinished run gets an ETA, whether or not it has
            %   reported yet: a run that has not reported is not waiting for
            %   anything, it is simply early, so the cost model's estimate is
            %   the honest answer and is marked "~" to say it is a projection
            %   rather than a measurement.
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
            %   The runner gives every run its own worker, so all of them are
            %   in flight from the start and none is waiting on another. The
            %   batch therefore ends when its slowest run ends, and no
            %   scheduling is involved: the maximum of the per-run ETAs is
            %   exact given those ETAs, rather than an approximation of how
            %   the pool would have packed a queue.
            %
            %   The old estimate, elapsed/meanFraction - elapsed, is kept as
            %   the fallback for when no run has reported and no cost model
            %   was supplied. It is only correct when every run is in flight
            %   at once, which here it is, but it says nothing at all until
            %   the first fraction arrives.
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
            %   Every state is counted explicitly, including the runs that
            %   have a worker but have not reported yet, so the states on the
            %   face of the window always sum to the batch and none of them
            %   has to be inferred by counting rows.
            active = ~obj.skipped;
            if any(active)
                overall = mean(obj.frac(active));
            else
                overall = 1;
            end
            if nargin < 2, etaSec = obj.eta(); end
            % The calibration factor is shown when it has moved off 1, so a
            % batch running well outside its projection says so on the face
            % of the window rather than only in the ETA.
            sc = obj.calScale();
            if abs(sc - 1) > 0.05 && any(isfinite(obj.priorWall))
                cal = sprintf('  |  cost x%.2f vs model', sc);
            else
                cal = '';
            end
            % Counted per state rather than from doneCount, which counts a
            % failed run as done, so the four numbers always sum to the batch.
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
            if obj.mode == "text" && ~obj.enabled
                return;
            end
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
            % Computed once per redraw and passed to the header, so the header
            % and the rows of a frame are read off the same calibration.
            etaSec = obj.eta();
            msg = obj.headline(etaSec);

            switch obj.mode
                case "perrun"
                    if isempty(obj.fig) || ~isvalid(obj.fig)
                        return;   % user closed the window; keep running
                    end
                    obj.barH.YData = obj.frac;      % barh: YData is bar length
                    obj.barH.CData = obj.stateColours();
                    % Re-assert the axes geometry after touching the bar data.
                    % Updating a Bar can put the rulers back into automatic
                    % mode, which is what produced four auto ticks and a
                    % window of recycled labels before the row text moved into
                    % text objects. The text lives in data coordinates, so the
                    % rows and the bars stay aligned either way, but pinning
                    % the limits keeps every run on screen.
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
                    % Print only when the percentage actually moves, so a
                    % long batch does not fill the command window.
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
            %compactDur Two significant units, for a readout, not a stopwatch.
            %   fmtDuration is kept for the printed record, where "33 h 03 min
            %   27 s" is fine. In a row of a live window the seconds are noise
            %   and the width is what pushes the ETA column off the end of the
            %   text, so a 33 hour estimate reads "1d 9h".
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
