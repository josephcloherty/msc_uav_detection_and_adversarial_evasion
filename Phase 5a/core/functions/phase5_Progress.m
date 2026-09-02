classdef phase5_Progress < handle
% client-side progress reporter for a batch: one row per run, fed by messages
% workers send through a DataQueue, with a per-run and batch ETA.

    properties
        nRuns                       % enumerated runs
        labels          string      % run labels
        frac            double      % simulated-time fraction
        state           string      % per-run state
        skipped         logical     % excluded from the total
        startTic                    % batch wall clock
        mode            string = "text"   % display mode
        enabled         = true      % live display on
        minRedraw       = 0.5       % seconds between redraws
        lastRedrawTic
        lastTextPct     = -1        % last printed percentage
        doneCount       = 0

        % cost and ETA state, one entry per run
        priorWall       double      % cost-model estimate
        selfWall        double      % worker wall time
        lastFrac        double      % fraction at that time
        rate            double      % fraction per second
        ratio           double      % measured over prior
        ratioW          double      % confidence weight
        rateAlpha       = 0.35      % EWMA weight
        numWorkers      = 1         % pool size
        lastRowText     string      % last text written
        statusFile      = ""        % plain-text status board
    end

    properties (Access = private)
        fig    = []                 % uifigure
        ax     = []                 % uiaxes
        barH   = []                 % progress bars
        trackH = []                 % row backgrounds
        txt    = []                 % row labels
        hdr    = []                 % header label
        bar    = []                 % classic waitbar
    end

    properties (Constant, Access = private)
        % state colours, muted except failure
        COL_PENDING = [0.55 0.57 0.62];
        COL_RUNNING = [0.20 0.42 0.72];
        COL_OK      = [0.24 0.60 0.36];
        COL_FAILED  = [0.78 0.20 0.20];
        COL_SKIPPED = [0.42 0.44 0.48];
        COL_SALVAGED= [0.86 0.60 0.20];   % partial rows kept
        COL_TRACK   = [0.30 0.31 0.34];   % empty part of a row

        % width of the text column, in bar-length units
        LABELW = 0.72;
    end

    methods
        function obj = phase5_Progress(labels, pcfg, opts)
            % builds the reporter; opts carries the cost prior and pool size.
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
                    % fall back to the aggregate waitbar rather than
                    % failing the batch
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
            drawnow;   % paint before parfor blocks
        end

        function markSkipped(obj, mask)
            % excludes runs already on disk.
            mask = logical(mask(:))';
            obj.skipped(mask) = true;
            obj.state(mask)   = "skipped";
            obj.frac(mask)    = 1;
            obj.draw(true);
        end

        function update(obj, msg)
            % handles one message from a worker.
            switch string(msg.kind)
                case "progress"
                    % max() guards out-of-order delivery
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
                    % ignore unknown message kinds
            end
        end

        function close(obj)
            % tears down whichever display was built.
            if ~isempty(obj.fig) && isvalid(obj.fig), delete(obj.fig); end
            if ~isempty(obj.bar) && isvalid(obj.bar), delete(obj.bar); end
            obj.fig = []; obj.bar = [];
        end
    end

    methods (Access = private)
        function buildPerRunWindow(obj)
            % builds one labelled row per run in a single axes.
            n = obj.nRuns;
            % size from the run count and clamp to the screen
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

            obj.ax.YDir  = 'reverse';        % run 1 on top
            obj.ax.XLim  = [-obj.LABELW 1];  % text region
            obj.ax.YLim  = [0.5 n+0.5];
            obj.ax.YTick = [];               % no tick labels
            obj.ax.XTick = 0:0.25:1;
            obj.ax.XTickLabel = {'0','25','50','75','100%'};
            obj.ax.FontName = 'Consolas';
            obj.ax.FontSize = fs;
            obj.ax.Box = 'off';
            obj.ax.XGrid = 'on';

            % one text object per row, coloured from the ruler so it reads
            % under either desktop theme
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
            % writes each row: name, percentage, state and its own ETA.
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
            % returns one row of the status board.
            s = string(sprintf('%-13s %3.0f%%  %-8s %s', obj.labels(i), ...
                100*obj.frac(i), obj.stateWord(i), obj.runEtaText(i)));
        end

        function writeStatusFile(obj, msg)
            % writes the whole board as plain text, so a batch with no desktop
            % is still watchable. failure is ignored on purpose.
            if strlength(obj.statusFile) == 0, return; end
            try
                fid = fopen(char(obj.statusFile), 'w');
                if fid < 0, return; end
                fprintf(fid, 'Phase 5 batch, %s\n%s\n\n', ...
                    char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), msg);
                for i = 1:obj.nRuns
                    fprintf(fid, '%s\n', obj.rowText(i));
                end
                fclose(fid);
            catch
            end
        end

        function w = stateWord(obj, i)
            % returns the word for a run's state.
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
            % folds one progress report into this run's rate estimate, taken
            % from the change since the previous report.
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

            % recalibrate the cost model against this run in flight
            if obj.rate(i) > 0 && isfinite(obj.priorWall(i)) && obj.priorWall(i) > 0
                obj.ratio(i)  = (1/obj.rate(i)) / obj.priorWall(i);
                obj.ratioW(i) = max(f, 0);
            end
        end

        function closeOut(obj, msg)
            % records a finished run's measured cost as the best calibration.
            i = msg.run;
            if ~isfield(msg, 'wall'), return; end
            w = double(msg.wall);
            if ~isfinite(w) || w <= 0, return; end
            obj.selfWall(i) = w;
            obj.rate(i) = 1/w;
            if isfinite(obj.priorWall(i)) && obj.priorWall(i) > 0
                obj.ratio(i)  = w / obj.priorWall(i);
                obj.ratioW(i) = 1;      % measured fully
            end
        end

        function s = calScale(obj)
            % returns the weighted correction from the cost model to this machine.
            sel = isfinite(obj.ratio) & obj.ratioW > 0;
            if ~any(sel)
                s = 1;
            else
                s = sum(obj.ratio(sel) .* obj.ratioW(sel)) / sum(obj.ratioW(sel));
            end
            if ~isfinite(s) || s <= 0, s = 1; end
        end

        function w = expectedWall(obj, i)
            % returns the recalibrated cost-model estimate for one run.
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
            % returns the seconds remaining for one run, by measured rate or model.
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
            % returns what a row says to the right of its state, marking a
            % projection with a tilde.
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
            % returns the batch seconds remaining: the slowest run still going.
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
            % returns the mean-percentage extrapolation, the pre-model fallback.
            active = ~obj.skipped;
            elapsed = toc(obj.startTic);
            overall = mean(obj.frac(active));
            if overall <= 0
                e = NaN;                        % nothing yet
            else
                e = elapsed/overall - elapsed;
            end
        end

        function s = headline(obj, etaSec)
            % returns the aggregate line, counting every state explicitly.
            active = ~obj.skipped;
            if any(active)
                overall = mean(obj.frac(active));
            else
                overall = 1;
            end
            if nargin < 2, etaSec = obj.eta(); end
            % show the calibration factor once it has moved off 1
            sc = obj.calScale();
            if abs(sc - 1) > 0.05 && any(isfinite(obj.priorWall))
                cal = sprintf('  |  cost x%.2f vs model', sc);
            else
                cal = '';
            end
            % counted per state, so the numbers sum to the batch
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
            % computed once per redraw, so header and rows agree
            etaSec = obj.eta();
            msg = obj.headline(etaSec);

            % written in every mode: the file is the only readout that
            % survives losing the desktop
            obj.writeStatusFile(msg);
            if obj.mode == "text" && ~obj.enabled
                return;              % no live display
            end

            switch obj.mode
                case "perrun"
                    if isempty(obj.fig) || ~isvalid(obj.fig)
                        return;   % window closed
                    end
                        obj.barH.YData = obj.frac;      % bar length
                    obj.barH.CData = obj.stateColours();
                    % re-assert the axes geometry after touching the bar data
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
                    % print only when the percentage moves
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
            % formats a duration to two units, for a live readout rather than
            % a stopwatch.
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
