classdef phase7_Progress < handle
%phase7_Progress Command-line batch progress reporter.
%
%   Runs execute on workers with no display, so the client collects progress
%   and prints it. Nothing is drawn in a figure.
%
%   Workers send two kinds of message down a parallel.pool.DataQueue:
%     struct('kind',"progress",'run',i,'frac',f,'wall',w)  periodic
%     struct('kind',"done",'run',i,'status',s,'wall',w)    once per run
%
%   What gets printed:
%     - an aggregate line whenever the overall percentage moves
%     - one line per run as it finishes
%     - a DONE block from finish()
%
%   Each run's rate is an exponentially weighted mean of simulated fraction
%   per worker-second, so a run that slows down is followed rather than
%   averaged over its whole history. Runs that have not started are
%   estimated from the cost model and then queued onto workers longest
%   first.
%
%   Usage:
%       prog = phase7_Progress(labels, cfg.progress, opts);
%       prog.markSkipped(~todo);
%       q = parallel.pool.DataQueue;
%       afterEach(q, @(m) prog.update(m));
%       ... parfor ...
%       prog.finish();
%
%   Reads enable, updatesPerRun, rateAlpha and minPrint_s from cfg.progress.

    properties
        nRuns                       % number of enumerated runs
        labels          string      % 1 x nRuns, e.g. "UMa seed 7"
        frac            double      % 1 x nRuns, simulated-time fraction
        state           string      % pending | running | ok | failed | skipped
        skipped         logical     % excluded from the progress denominator
        startTic                    % batch wall clock
        enabled         = true      % false: no aggregate lines
        minPrint        = 5         % s, minimum gap between aggregate lines
        lastPrintTic
        lastTextPct     = -1        % last percentage printed
        doneCount       = 0

        % cost and ETA state, all 1 x nRuns
        priorWall       double      % cost-model estimate per run, s
        selfWall        double      % last wall time reported by the worker
        lastFrac        double      % fraction at that wall time
        rate            double      % EWMA of fraction per worker-second
        ratio           double      % measured cost / prior cost, per run
        ratioW          double      % confidence weight for that ratio
        rateAlpha       = 0.35      % EWMA weight on the newest sample
        numWorkers      = 1         % pool size, for the batch estimate
    end

    methods
        function obj = phase7_Progress(labels, pcfg, opts)
            %phase7_Progress OPTS carries the cost-model prior and pool size.
            %   opts.priorWall_s  expected wall time per run, from
            %                     phase7_CostModel; NaN falls back to
            %                     extrapolating the mean percentage
            %   opts.numWorkers   pool size, for the batch estimate
            obj.labels  = string(labels(:))';
            obj.nRuns   = numel(obj.labels);
            obj.frac    = zeros(1, obj.nRuns);
            obj.state   = repmat("pending", 1, obj.nRuns);
            obj.skipped = false(1, obj.nRuns);
            obj.startTic = tic;
            obj.lastPrintTic = tic;

            obj.priorWall = nan(1, obj.nRuns);
            obj.selfWall  = zeros(1, obj.nRuns);
            obj.lastFrac  = zeros(1, obj.nRuns);
            obj.rate      = zeros(1, obj.nRuns);
            obj.ratio     = nan(1, obj.nRuns);
            obj.ratioW    = zeros(1, obj.nRuns);

            if nargin >= 2 && ~isempty(pcfg)
                if isfield(pcfg, 'enable'),    obj.enabled   = pcfg.enable;    end
                if isfield(pcfg, 'minPrint_s'),obj.minPrint  = pcfg.minPrint_s;end
                if isfield(pcfg, 'rateAlpha'), obj.rateAlpha = pcfg.rateAlpha; end
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
        end

        function markSkipped(obj, mask)
            %markSkipped Exclude runs that are already on disk.
            mask = logical(mask(:))';
            obj.skipped(mask) = true;
            obj.state(mask)   = "skipped";
            obj.frac(mask)    = 1;
        end

        function update(obj, msg)
            %update Handle one message from a worker.
            switch string(msg.kind)
                case "progress"
                    % max() guards against out-of-order delivery.
                    i = msg.run;
                    obj.frac(i)  = max(obj.frac(i), msg.frac);
                    obj.state(i) = "running";
                    obj.observe(i, msg);
                    obj.print(false);
                case "done"
                    obj.frac(msg.run)  = 1;
                    obj.state(msg.run) = string(msg.status);
                    obj.doneCount = obj.doneCount + 1;
                    obj.closeOut(msg);
                    obj.printRunLine(msg.run);
                otherwise
                    % Ignore unknown kinds, since the reporter must never be
                    % able to take down a running batch.
            end
        end

        function finish(obj)
            %finish Print the DONE block once every run is accounted for.
            active  = ~obj.skipped;
            nOK     = sum(obj.state == "ok");
            nFail   = sum(obj.state == "failed");
            nSkip   = sum(obj.state == "skipped");
            nOther  = obj.nRuns - nOK - nFail - nSkip;
            bar = repmat('=', 1, 64);
            fprintf('\n%s\n', bar);
            fprintf('DONE  all %d scenario run(s) finished in %s\n', ...
                obj.nRuns, fmtDuration(toc(obj.startTic)));
            fprintf('      %d ok, %d failed, %d skipped', nOK, nFail, nSkip);
            if nOther > 0
                fprintf(', %d unreported', nOther);
            end
            fprintf('\n');
            if sum(active) > 0
                fprintf('      %d run(s) executed this batch\n', sum(active));
            end
            fprintf('%s\n', bar);
        end

        function close(obj) %#ok<MANU>
            %close Kept so callers can use onCleanup; nothing to tear down.
        end
    end

    methods (Access = private)
        function observe(obj, i, msg)
            %observe Fold one progress report into this run's rate estimate.
            %   The rate comes from the change since the last report, not the
            %   run's average, so a run that slows down is tracked.
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

            % Weight the recalibration by fraction completed, so an early
            % guess counts for little.
            if obj.rate(i) > 0 && isfinite(obj.priorWall(i)) && obj.priorWall(i) > 0
                obj.ratio(i)  = (1/obj.rate(i)) / obj.priorWall(i);
                obj.ratioW(i) = max(f, 0);
            end
        end

        function closeOut(obj, msg)
            %closeOut Use a finished run's measured cost as the calibration.
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
            %   With no cost model, falls back to the median measured cost of
            %   the runs that have reported.
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

        function printRunLine(obj, i)
            %printRunLine One line for a run that has just finished.
            active = ~obj.skipped;
            if obj.selfWall(i) > 0
                own = sprintf('%s run, ', fmtDuration(obj.selfWall(i)));
            else
                own = '';
            end
            fprintf('[%3d/%3d] %-22s %-8s (%s%s elapsed, batch ETA %s)\n', ...
                obj.doneCount, sum(active), obj.labels(i), obj.state(i), ...
                own, fmtDuration(toc(obj.startTic)), fmtDuration(obj.eta()));
        end

        function e = eta(obj)
            %eta Batch seconds remaining, by scheduling the queue onto workers.
            %   Running runs hold a worker until their own ETA expires, then
            %   pending runs go longest-first onto whichever frees up next.
            active = ~obj.skipped;
            if ~any(active)
                e = 0;
                return;
            end

            running = find(active & obj.state == "running");
            pending = find(active & obj.state == "pending");

            haveModel = any(isfinite(obj.priorWall(active)));
            if isempty(running) && ~haveModel
                e = obj.naiveEta();
                return;
            end

            nW = max(obj.numWorkers, 1);
            free = zeros(1, nW);
            % Occupied workers, longest remaining first.
            rem = sort(arrayfun(@(i) obj.runEta(i), running), 'descend');
            rem = rem(isfinite(rem));
            nOcc = min(numel(rem), nW);
            free(1:nOcc) = rem(1:nOcc);
            spill = 0;
            if numel(rem) > nW
                % Cannot happen under parfor, but handle it so a bookkeeping
                % slip cannot produce a short ETA.
                spill = sum(rem(nW+1:end)) / nW;
            end

            % Pending work, longest first onto the earliest free worker.
            q = arrayfun(@(i) obj.expectedWall(i), pending);
            q = q(isfinite(q) & q > 0);
            q = sort(q, 'descend');
            for k = 1:numel(q)
                [~, j] = min(free);
                free(j) = free(j) + q(k);
            end

            e = max(free) + spill;
            if ~isfinite(e), e = obj.naiveEta(); end
        end

        function e = naiveEta(obj)
            %naiveEta Mean-percentage extrapolation, used as a last resort.
            %   Only correct when every run is in flight at once.
            active = ~obj.skipped;
            elapsed = toc(obj.startTic);
            overall = mean(obj.frac(active));
            if overall <= 0
                e = NaN;                        % nothing to estimate from yet
            else
                e = elapsed/overall - elapsed;
            end
        end

        function s = headline(obj)
            %headline The aggregate status line.
            active = ~obj.skipped;
            if any(active)
                overall = mean(obj.frac(active));
            else
                overall = 1;
            end
            % Show the calibration factor once it has moved off 1.
            sc = obj.calScale();
            if abs(sc - 1) > 0.05 && any(isfinite(obj.priorWall))
                cal = sprintf('  |  cost x%.2f vs model', sc);
            else
                cal = '';
            end
            s = sprintf(['runs %d/%d done, %d running  |  overall %.1f%%' ...
                '  |  wall %s  |  ETA %s%s'], obj.doneCount, sum(active), ...
                sum(obj.state == "running"), 100*overall, ...
                fmtDuration(toc(obj.startTic)), fmtDuration(obj.eta()), cal);
        end

        function print(obj, force)
            %print Aggregate line, throttled by percentage and by time.
            %   Progress is the mean simulated-time fraction over the runs
            %   being executed rather than a count of finished ones, so a
            %   batch of long runs does not sit at zero for hours.
            %   Skipped runs stay out of the denominator.
            if ~obj.enabled
                return;
            end
            active = ~obj.skipped;
            if any(active)
                overall = mean(obj.frac(active));
            else
                overall = 1;
            end
            pct = floor(100*overall);
            if ~force
                if pct == obj.lastTextPct, return; end
                if toc(obj.lastPrintTic) < obj.minPrint, return; end
            end
            obj.lastTextPct = pct;
            obj.lastPrintTic = tic;
            fprintf('[%5.1f%%] %s\n', 100*overall, obj.headline());
        end
    end
end
