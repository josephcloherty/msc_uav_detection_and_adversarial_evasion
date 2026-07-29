function replayScenario(posLog, gNBs, UEs, managers, buildings, extras)
%replayScenario Post-run 3D scrollable replay of node positions with
% serving-cell lines, building geometry, and per-timestamp statistics.
%
%   replayScenario(POSLOG, GNBS, UES, MANAGERS)
%   replayScenario(POSLOG, GNBS, UES, MANAGERS, BUILDINGS)
%   replayScenario(POSLOG, GNBS, UES, MANAGERS, BUILDINGS, EXTRAS)
%
%   POSLOG    - struct with fields times (1xT), xyz (Nx3xT), nodeIDs (1xN),
%               produced by positionRecorder.toStruct().
%   GNBS      - array of nrGNB objects.
%   UES       - array of nrUE objects (unused directly but kept for clarity).
%   MANAGERS  - cell array of handoverManager objects. Each must expose
%               featureLog, ueLabel and UE. The featureLog column order is
%               assumed to match featureNames defined in the handover manager:
%               {time, ueID, label_is_aerial, servingGNB, servingSINR,
%                numVisible, maxNeighbourSINR, meanNeighbourSINR, sinrSpread,
%                handoverCount, timeSinceLastHO, ...}.
%   BUILDINGS - (optional) N-by-6 matrix, one row per building, columns
%               [xmin xmax ymin ymax zmin zmax]. This is the same
%               buildingsAABB matrix built in the scenario script, so adding
%               a building there propagates here automatically. Omit or pass
%               [] for no buildings.
%   EXTRAS    - (optional, Phase 3) struct carrying the scenario config and
%               link states so channel information can be shown inside the
%               3D view. Fields:
%                 .cfg      scenario config (scenario, zBoundary,
%                           avgBuildingHeight, windowLen, settleTime,
%                           replayCullTime, ...)
%                 .linkInfo per-link LOS states from createScenarioChannels
%               The replay drops the settle span (cfg.settleTime) and
%               re-zeroes the clock, so playback opens after the initial
%               attach and handover burst instead of with every UE at its
%               spawn point, and the settle-gated data excluded from the
%               dataset never appears in the viewer either.
%               cfg.replayCullTime, if set, extends the cull beyond the
%               settle time (it cannot shorten it). Saved replays store
%               the un-culled log and re-cull on reload, and the manager
%               objects are never modified, so the dataset and statistics
%               keep absolute time.
%               When present, each serving line is coloured by its drawn
%               LOS state (solid blue LOS, dashed red NLOS) and annotated
%               at its midpoint with the Table B-1 LOS probability, the
%               geometric ZoD, and the Annex B.1.1 Step 5 ZOD offset at
%               the current positions. The readout gains a per-UE sliding
%               window block (windowed serving-SINR mean and variance,
%               handover count, and mean inter-handover interval over the
%               trailing cfg.windowLen seconds), the UE's trail over that
%               window is drawn in 3D, and times inside cfg.settleTime are
%               marked as settle (excluded from the dataset). Phase 2
%               replays without EXTRAS behave exactly as before, and saved
%               replay files round-trip the struct.
%
%   Drag the slider to scrub through simulation time. At each timestamp the
%   plot shows node positions in 3D, building footprints/volumes, a blue line
%   from each UE to its serving gNB (taken from the latest feature row at or
%   before that time), gold star markers at past handover locations, and a
%   full readout of every logged statistic per UE in the right-hand panel.
%
%   SAVING / RELOADING A REPLAY
%   ---------------------------
%   While the replay window is open, click "Save Replay..." to write every
%   input (posLog, gNBs, UEs, managers, buildings) into a single .mat file.
%   To watch it again later, just pass that file back in:
%
%       replayScenario('myReplay.mat')   % or replayScenario() to browse
%
%   The reloaded session is identical to the original because all simulation
%   data lives inside the one file.

    % ---- Reload mode: replayScenario(FILENAME) or replayScenario() ----------
    % If called with a single char/string (a saved .mat path), or with no
    % arguments at all, load the bundled simulation data and replay it.
    if nargin <= 1 && (nargin == 0 || ischar(posLog) || isstring(posLog))
        if nargin == 0
            fname = '';
        else
            fname = char(posLog);
        end
        if isempty(fname) || exist(fname,'file') ~= 2
            [f,p] = uigetfile({'*.mat','Saved replay (*.mat)'}, ...
                'Open saved replay');
            if isequal(f,0), return; end   % user cancelled
            fname = fullfile(p,f);
        end
        S = load(fname);
        if ~isfield(S,'replayData')
            error('replayScenario:badFile', ...
                '%s does not contain a saved replay (missing replayData).', fname);
        end
        d = S.replayData;
        if isfield(d,'buildings'), bld = d.buildings; else, bld = []; end
        if isfield(d,'extras'),    ex  = d.extras;    else, ex  = []; end
        replayScenario(d.posLog, d.gNBs, d.UEs, d.managers, bld, ex);
        return;
    end

    if nargin < 5 || isempty(buildings)
        buildings = zeros(0,6);   % no buildings
    end
    if nargin < 6
        extras = [];              % Phase 2 replays carry no channel info
    end

    % Sliding-window and settle settings from the scenario config (extras)
    winLen = 10;  settleT = 0;  hasExtras = isstruct(extras);
    if hasExtras && isfield(extras,'cfg')
        if isfield(extras.cfg,'windowLen'),  winLen  = extras.cfg.windowLen;  end
        if isfield(extras.cfg,'settleTime'), settleT = extras.cfg.settleTime; end
    end

    % featureLog column indices (must match handoverManager.featureNames)
    COL_TIME    = 1;
    COL_SERVGNB = 4;
    COL_SERVSINR= 5;
    COL_NUMVIS  = 6;
    COL_MAXN    = 7;
    COL_MEANN   = 8;
    COL_SPREAD  = 9;
    COL_HO      = 10;
    COL_TSINCE  = 11;

    % ---- Start-up cull: drop the first cfg.replayCullTime seconds and ----
    % re-zero the clock, so the replay opens after the initial attach and
    % handover burst have resolved rather than with every UE stacked at
    % its spawn point. The uncoloured originals are kept for saving, so a
    % saved replay reloads and re-culls identically. Phase 2 replays (no
    % extras) are untouched.
    % Legacy repair: recordings made before the positionRecorder fix carry
    % a spurious all-zero first frame (one more frame than timestamps).
    % Dropping it realigns times and positions for old saves; recordings
    % made after the fix are unaffected.
    if size(posLog.xyz, 3) == numel(posLog.times) + 1
        posLog.xyz(:,:,1) = [];
    end

    posLogRaw = posLog;               % saved verbatim by saveReplay
    % The replay always culls at least the settle span, so settle-gated
    % data (already excluded from the dataset by extractWindowedFeatures)
    % never appears in the viewer either. cfg.replayCullTime, if set,
    % can only extend the cull beyond the settle time.
    cull = 0;
    if hasExtras && isfield(extras,'cfg')
        if isfield(extras.cfg,'settleTime')
            cull = extras.cfg.settleTime;
        end
        if isfield(extras.cfg,'replayCullTime')
            cull = max(cull, extras.cfg.replayCullTime);
        end
    end
    if cull > 0
        keepF = posLog.times >= cull;
        if any(keepF)
            posLog.times = posLog.times(keepF) - cull;
            posLog.xyz   = posLog.xyz(:,:,keepF);
        end
        settleT = max(settleT - cull, 0);
    end

    % Local, time-shifted copies of the per-UE logs (the manager objects
    % themselves are never modified; the dataset always uses absolute time)
    featLogs = cell(numel(managers),1);
    hoLists  = cell(numel(managers),1);
    sinrLogs = cell(numel(managers),1);   % per-gNB SINR, [t, gNB1..N]
    for kk = 1:numel(managers)
        flk = managers{kk}.featureLog;
        if ~isempty(flk)
            flk = flk(flk(:,COL_TIME) >= cull, :);
            flk(:,COL_TIME) = flk(:,COL_TIME) - cull;
        end
        featLogs{kk} = flk;
        ht = managers{kk}.handoverTimes(:);
        hoLists{kk} = ht(ht >= cull) - cull;
        % Per-gNB SINR log (present on runs made after the sinrLog
        % addition to handoverManager; empty for older saves)
        slk = [];
        if isprop(managers{kk}, 'sinrLog') && ~isempty(managers{kk}.sinrLog)
            slk = managers{kk}.sinrLog;
            slk = slk(slk(:,1) >= cull, :);
            slk(:,1) = slk(:,1) - cull;
        end
        sinrLogs{kk} = slk;
    end

    nFrames = numel(posLog.times);
    if nFrames == 0
        error('replayScenario:emptyLog', ...
            'Position log is empty. Enable the position recorder before run.');
    end

    % Z-aspect compression so altitude is visible against the wide X-Y span.
    zAspect = 0.3;

    % ---- Layout: axes (top-left), controls (bottom-left), readout (right) ----
    fig = uifigure('Name','Scenario Replay','Position',[100 100 1220 770]);
    g = uigridlayout(fig,[2 2], ...
        'RowHeight',{'1x',60}, 'ColumnWidth',{'1x',360});

    ax = uiaxes('Parent',g);
    ax.Layout.Row = 1; ax.Layout.Column = 1;
    ax.DataAspectRatio = [1 1 zAspect];
    xlabel(ax,'X (m)'); ylabel(ax,'Y (m)'); zlabel(ax,'Z (m)');
    grid(ax,'on'); view(ax,3);

    % Readout panel spans both rows on the right -> full window height, no clip
    readout = uitextarea('Parent',g, 'Editable','off', ...
        'FontName','monospaced', 'FontSize',12);
    readout.Layout.Row = [1 2];
    readout.Layout.Column = 2;

    % Controls sit under the axes only
    ctrl = uigridlayout(g,[1 4], ...
        'ColumnWidth',{80,110,110,'1x'},'Padding',[2 2 2 2]);
    ctrl.Layout.Row = 2; ctrl.Layout.Column = 1;
    playBtn = uibutton(ctrl,'state','Text','Play','Value',false);
    saveBtn = uibutton(ctrl,'push','Text','Save Replay...');
    plotBtn = uibutton(ctrl,'push','Text','Plot Figures...');
    slider = uislider('Parent',ctrl, ...
        'Limits',[posLog.times(1) posLog.times(end)], ...
        'Value',posLog.times(1));

    saveBtn.ButtonPushedFcn = @(~,~) saveReplay();
    plotBtn.ButtonPushedFcn = @(~,~) plotFiguresDialog();
    slider.ValueChangingFcn = @(s,e) scrub(e.Value);

    function saveReplay()
        [f,p] = uiputfile({'*.mat','Saved replay (*.mat)'}, ...
            'Save replay and simulation data', 'scenarioReplay.mat');
        if isequal(f,0), return; end       % user cancelled
        replayData = struct( ...
            'posLog',    posLogRaw, ...   % un-culled: reload re-culls once
            'gNBs',      gNBs, ...
            'UEs',       UEs, ...
            'managers',  {managers}, ...   % cell wrapped to keep as one field
            'buildings', buildings, ...
            'extras',    extras, ...       % Phase 3 channel/window info ([] for Phase 2)
            'savedOn',   datestr(now)); %#ok<TNOW1,DATST>
        try
            save(fullfile(p,f), 'replayData', '-v7.3');
            uialert(fig, sprintf('Replay saved to:\n%s', fullfile(p,f)), ...
                'Saved', 'Icon','success');
        catch err
            uialert(fig, sprintf('Could not save replay:\n%s', err.message), ...
                'Save failed', 'Icon','error');
        end
    end

    % ---- Plot selected variables over time ----------------------------------
    % Every series the replay data can support, not just the logged feature
    % columns. Selecting several entries produces one figure with a panel
    % per variable and one line per UE. Series unavailable for a given save
    % (e.g. per-gNB SINR on runs made before sinrLog existed, or live
    % channel values without extras) simply plot nothing for that panel.
    function names = plottableNames()
        names = { ...
            'servingSINR','maxNeighbourSINR','meanNeighbourSINR', ...
            'sinrMargin','sinrSpread','numVisible','servingGNB', ...
            'handoverCount','timeSinceLastHO','label_is_aerial'};
        for gg = 1:numel(gNBs)                    % per-gNB SINR series
            names{end+1} = sprintf('SINR_gNB%d', gNBs(gg).ID); %#ok<AGROW>
        end
        names = [names, {'altitude_m','speed2D_mps','dist2D_serving_m', ...
            'dist3D_serving_m'}];
        for gg = 1:numel(gNBs)                    % per-gNB distances
            names{end+1} = sprintf('dist2D_gNB%d_m', gNBs(gg).ID); %#ok<AGROW>
        end
        if hasExtras
            names = [names, {'pLOS_serving','losState_serving', ...
                'zodOffset_serving_deg'}];
        end
        names = [names, {'win_servSINR_mean','win_servSINR_var', ...
            'win_hoCount','win_meanInterHO_s'}];
    end

    function [ts, ys] = getSeries(vname, k)
    %getSeries Time base and values of one derived series for manager k.
    %   All series use the culled, re-zeroed clock. Returns empties when
    %   the save cannot supply the series.
        ts = []; ys = [];
        fl = featLogs{k};
        m = managers{k};
        ueID = m.UE.ID;
        colOf = containers.Map( ...
            {'servingGNB','servingSINR','numVisible','maxNeighbourSINR', ...
             'meanNeighbourSINR','sinrSpread','handoverCount', ...
             'timeSinceLastHO','label_is_aerial'}, ...
            {COL_SERVGNB, COL_SERVSINR, COL_NUMVIS, COL_MAXN, COL_MEANN, ...
             COL_SPREAD, COL_HO, COL_TSINCE, 3});

        if isKey(colOf, vname)
            if isempty(fl), return; end
            ts = fl(:,COL_TIME); ys = fl(:,colOf(vname));
            return;
        end
        switch vname
            case 'sinrMargin'
                if isempty(fl), return; end
                ts = fl(:,COL_TIME);
                ys = fl(:,COL_SERVSINR) - fl(:,COL_MAXN);
            case 'altitude_m'
                ts = posLog.times(:);
                ys = squeeze(posLog.xyz(posLog.nodeIDs == ueID, 3, :));
            case 'speed2D_mps'
                tr = squeeze(posLog.xyz(posLog.nodeIDs == ueID, 1:2, :));
                dt = diff(posLog.times(:));
                ts = posLog.times(2:end).';
                ys = vecnorm(diff(tr, 1, 2), 2, 1).' ./ dt(:);
            case {'dist2D_serving_m','dist3D_serving_m','pLOS_serving', ...
                  'losState_serving','zodOffset_serving_deg'}
                if isempty(fl), return; end
                [ts, ys] = servingGeometrySeries(vname, k);
            case {'win_servSINR_mean','win_servSINR_var','win_hoCount', ...
                  'win_meanInterHO_s'}
                if isempty(fl), return; end
                [ts, ys] = windowedSeries(vname, k);
            otherwise
                % Per-gNB series: SINR_gNB<i> and dist2D_gNB<i>_m
                tok = regexp(vname, '^SINR_gNB(\d+)$', 'tokens', 'once');
                if ~isempty(tok)
                    gID = str2double(tok{1});
                    sl = sinrLogs{k};
                    if ~isempty(sl) && size(sl,2) >= 1 + gID
                        ts = sl(:,1); ys = sl(:,1 + gID);
                    end
                    return;
                end
                tok = regexp(vname, '^dist2D_gNB(\d+)_m$', 'tokens', 'once');
                if ~isempty(tok)
                    gID = str2double(tok{1});
                    tr = squeeze(posLog.xyz(posLog.nodeIDs == ueID, 1:2, :));
                    gxy = squeeze(posLog.xyz(posLog.nodeIDs == gID, 1:2, :));
                    ts = posLog.times(:);
                    ys = vecnorm(tr - gxy, 2, 1).';
                end
        end
    end

    function [ts, ys] = servingGeometrySeries(vname, k)
    %servingGeometrySeries Live geometry towards the CURRENT serving cell.
        fl = featLogs{k};
        ueID = managers{k}.UE.ID;
        ts = posLog.times(:);
        ys = nan(numel(ts), 1);
        uTr = squeeze(posLog.xyz(posLog.nodeIDs == ueID, :, :));   % 3 x T
        for ii = 1:numel(ts)
            r = find(fl(:,COL_TIME) <= ts(ii), 1, 'last');
            if isempty(r), continue; end
            gID = fl(r, COL_SERVGNB);
            gRow = find(posLog.nodeIDs == gID, 1);
            if isempty(gRow), continue; end
            gP = posLog.xyz(gRow, :, ii);
            uP = uTr(:, ii).';
            d2 = max(hypot(uP(1)-gP(1), uP(2)-gP(2)), 1);
            d3 = max(norm(uP - gP), 1);
            switch vname
                case 'dist2D_serving_m',  ys(ii) = d2;
                case 'dist3D_serving_m',  ys(ii) = d3;
                case 'pLOS_serving'
                    if hasExtras && isfield(extras,'cfg')
                        ys(ii) = tr36777LOSProbability( ...
                            extras.cfg.scenario, uP(3), d2);
                    end
                case 'losState_serving'
                    % The actual state, 1 = LOS and 0 = NLOS, from the
                    % same linkState the channel model used. Plotting this
                    % against pLOS_serving is the direct check that the
                    % state tracks the geometry: a flat line here beside a
                    % sweeping pLOS is the frozen-state symptom.
                    if hasExtras && isfield(extras,'linkInfo') ...
                            && isfield(extras,'cfg') ...
                            && exist('linkState','file') == 2
                        stII = linkState(extras.linkInfo, extras.cfg, ...
                            gID, ueID, gP, uP);
                        ys(ii) = double(stII.isLOS);
                    end
                case 'zodOffset_serving_deg'
                    if hasExtras && isfield(extras,'cfg')
                        c = extras.cfg;
                        if uP(3) > c.zBoundary
                            switch upper(string(c.scenario))
                                case "RMA"
                                    ys(ii) = atand((gP(3)+uP(3))/d2) + ...
                                             atand((uP(3)-gP(3))/d2);
                                case "UMA"
                                    ys(ii) = atand((gP(3)+uP(3) ...
                                        - 2*c.avgBuildingHeight)/d2) + ...
                                             atand((uP(3)-gP(3))/d2);
                                otherwise
                                    ys(ii) = 0;
                            end
                        else
                            ys(ii) = 0;
                        end
                    end
            end
        end
    end

    function [ts, ys] = windowedSeries(vname, k)
    %windowedSeries The D3.1 sliding-window features evaluated at every
    % scan time (trailing winLen window, settle excluded), so the plotted
    % curves are exactly what the dataset windows sample.
        fl = featLogs{k};
        ts = fl(:,COL_TIME);
        ys = nan(numel(ts), 1);
        hoT = hoLists{k};
        for ii = 1:numel(ts)
            w0 = max([ts(ii) - winLen, settleT, ts(1)]);
            inW = fl(:,COL_TIME) >= w0 & fl(:,COL_TIME) <= ts(ii);
            if ~any(inW), continue; end
            switch vname
                case 'win_servSINR_mean'
                    ys(ii) = mean(fl(inW,COL_SERVSINR), 'omitnan');
                case 'win_servSINR_var'
                    ys(ii) = var(fl(inW,COL_SERVSINR), 0, 'omitnan');
                case 'win_hoCount'
                    ys(ii) = sum(hoT >= w0 & hoT <= ts(ii));
                case 'win_meanInterHO_s'
                    h = hoT(hoT >= w0 & hoT <= ts(ii));
                    if numel(h) >= 2, ys(ii) = mean(diff(h)); end
            end
        end
    end

    function plotFiguresDialog()
        names = plottableNames();
        dlg = uifigure('Name','Plot variables over time', ...
            'Position',[200 200 340 480]);
        gl = uigridlayout(dlg,[3 1],'RowHeight',{30,'1x',32});
        uilabel(gl,'Text', ...
            'Select one or more variables (Ctrl/Shift-click for several):');
        lb = uilistbox(gl,'Items',names,'Multiselect','on', ...
            'Value',names(1));
        bg = uigridlayout(gl,[1 2],'ColumnWidth',{'1x','1x'},'Padding',[0 0 0 0]);
        uibutton(bg,'Text','Plot', ...
            'ButtonPushedFcn',@(~,~) doPlot(lb.Value, dlg));
        uibutton(bg,'Text','Cancel', ...
            'ButtonPushedFcn',@(~,~) delete(dlg));
    end

    function doPlot(selNames, dlg)
        if ischar(selNames), selNames = {selNames}; end
        if isempty(selNames), return; end
        delete(dlg);

        n = numel(selNames);
        if n <= 4, nc = 1; else, nc = 2; end      % two columns when many
        nr = ceil(n / nc);
        f = figure('Name','Replay - selected variables over time', ...
            'Position',[120 80 560*nc 190*nr + 90]);
        tl = tiledlayout(f, nr, nc, 'TileSpacing', 'compact', ...
            'Padding', 'compact');
        for s = 1:n
            ax2 = nexttile(tl); hold(ax2,'on');
            vname = selNames{s};
            plotted = false;
            for k = 1:numel(managers)
                [ts, ys] = getSeries(vname, k);
                if isempty(ts), continue; end
                plot(ax2, ts, ys, 'DisplayName', ...
                    sprintf('%s (%s)', managers{k}.UE.Name, ...
                    managers{k}.ueLabel));
                plotted = true;
            end
            ylabel(ax2, vname, 'Interpreter','none');
            grid(ax2,'on');
            if plotted
                legend(ax2,'show','Location','best');
            else
                text(ax2, 0.5, 0.5, 'not available for this save', ...
                    'Units','normalized','HorizontalAlignment','center');
            end
        end
        xlabel(tl, 'Time (s)');
        title(tl, 'Replay time series (settle culled, re-zeroed clock)');
        figure(f);   % bring to front
    end

    function scrub(tSel)
        if playBtn.Value                  % user grabbed slider mid-playback
            playBtn.Value = false;
            playBtn.Text = 'Play';
            stop(playTimer);
        end
        redraw(tSel);
    end

    % Real-time playback
    uiRate = 20;                          % UI refresh rate (Hz)
    playTimer = timer('ExecutionMode','fixedSpacing', ...
        'Period',1/uiRate, 'TimerFcn',@(~,~) playTick());
    lastTic = [];                         % wall-clock anchor for real-time stepping

    playBtn.ValueChangedFcn = @(s,~) togglePlay(s.Value);
    fig.CloseRequestFcn = @(~,~) cleanUp();   % stop timer on window close

    function togglePlay(isPlaying)
        if isPlaying
            playBtn.Text = 'Pause';
            % If at the end, restart from the beginning
            if slider.Value >= posLog.times(end) - eps
                slider.Value = posLog.times(1);
            end
            lastTic = tic;
            start(playTimer);
        else
            playBtn.Text = 'Play';
            stop(playTimer);
        end
    end

    function playTick()
        dt = toc(lastTic);                % real seconds since last tick
        lastTic = tic;
        tNew = slider.Value + dt;
        if tNew >= posLog.times(end)
            tNew = posLog.times(end);
            playBtn.Value = false;        % auto-pause at the end
            playBtn.Text = 'Play';
            stop(playTimer);
        end
        slider.Value = tNew;
        redraw(tNew);
    end

    function cleanUp()
        stop(playTimer); delete(playTimer);
        delete(fig);
    end

    % Fixed axis limits from the whole history (nodes AND buildings), so the
    % view does not jump while scrubbing and tall buildings are not clipped.
    allX = squeeze(posLog.xyz(:,1,:)); allY = squeeze(posLog.xyz(:,2,:));
    allZ = squeeze(posLog.xyz(:,3,:));
    pad = 50;
    xsAll = allX(:); ysAll = allY(:); zsAll = allZ(:);
    if ~isempty(buildings)
        xsAll = [xsAll; buildings(:,1); buildings(:,2)];
        ysAll = [ysAll; buildings(:,3); buildings(:,4)];
        zsAll = [zsAll; buildings(:,6)];
    end
    xL = [min(xsAll)-pad, max(xsAll)+pad];
    yL = [min(ysAll)-pad, max(ysAll)+pad];
    zL = [0, max(zsAll)+pad];

    % Precompute handover events: time and UE position at each HO
    hoEvents = [];   % columns: [time x y z]
    for k = 1:numel(managers)
        fl = featLogs{k};   % culled/re-zeroed copy
        if size(fl,1) < 2, continue; end
        hoIdx = find(diff(fl(:,COL_HO)) > 0) + 1;   % rows where count increments
        ueID = managers{k}.UE.ID;
        for j = hoIdx'
            tHO = fl(j,COL_TIME);
            [~,fI] = min(abs(posLog.times - tHO));          % nearest logged frame
            p = posLog.xyz(posLog.nodeIDs == ueID, :, fI);
            hoEvents(end+1,:) = [tHO p]; %#ok<AGROW>
        end
    end

    redraw(posLog.times(1));   % initial frame

    function redraw(tSel)
        % Snap to nearest logged frame
        [~,fIdx] = min(abs(posLog.times - tSel));
        t = posLog.times(fIdx);
        frame = posLog.xyz(:,:,fIdx);    % N x 3

        cla(ax); hold(ax,'on');
        xlim(ax,xL); ylim(ax,yL); zlim(ax,zL);

        % Label/mast colour with enough contrast for the active theme
        % (dark mode left the default black text unreadable).
        lblCol = fgColour(ax, fig);

        % Buildings (static geometry, redrawn each frame because cla wipes)
        drawBuildings(ax, buildings);

        % gNBs (first numel(gNBs) entries of the node list)
        nG = numel(gNBs);
        for i = 1:nG
            gID = gNBs(i).ID;
            gPos = frame(posLog.nodeIDs == gID, :);
            scatter3(ax,gPos(1),gPos(2),gPos(3),90,'^','filled', ...
                'MarkerFaceColor',[0.20 0.40 0.80]);
            % Mast from the gNB straight down to ground level (z = 0)
            plot3(ax,[gPos(1) gPos(1)],[gPos(2) gPos(2)],[gPos(3) 0], ...
                '-','Color',lblCol,'LineWidth',1.5);
            text(ax,gPos(1),gPos(2),gPos(3)+8,"gNB"+gID, ...
                'FontSize',8,'HorizontalAlignment','center','Color',lblCol);
        end

        % UEs + serving line + per-UE readout
        lines = {};
        for k = 1:numel(managers)
            m = managers{k};
            ueID = m.UE.ID;
            uPos = frame(posLog.nodeIDs == ueID, :);
            scatter3(ax,uPos(1),uPos(2),uPos(3),90,'o','filled', ...
                'MarkerFaceColor',[0.85 0.30 0.20]);
            text(ax,uPos(1),uPos(2),uPos(3)+8,m.ueLabel, ...
                'FontSize',8,'HorizontalAlignment','center','Color',lblCol);

            % Sliding-window indicator: the UE's path over the trailing
            % feature window [t - winLen, t], drawn as a solid gold trail
            % with a marker at the window start.
            inWin = posLog.times >= (t - winLen) & posLog.times <= t;
            if nnz(inWin) > 1
                tr = squeeze(posLog.xyz(posLog.nodeIDs == ueID, :, inWin));
                plot3(ax, tr(1,:), tr(2,:), tr(3,:), '-', ...
                    'Color', [0.95 0.75 0.10], 'LineWidth', 2);
                scatter3(ax, tr(1,1), tr(2,1), tr(3,1), 40, 'o', ...
                    'MarkerEdgeColor', [0.95 0.75 0.10], 'LineWidth', 1.5);
            end

            % Latest feature row at or before current time
            servGNB = NaN; servSINR = NaN; numVis = NaN; maxN = NaN; ...
                meanN = NaN; spread = NaN; hoCount = NaN; tSince = NaN;
            fl = featLogs{k};   % culled/re-zeroed copy
            if ~isempty(fl)
                past = fl(fl(:,COL_TIME) <= t, :);
                if ~isempty(past)
                    r = past(end,:);
                    servGNB  = r(COL_SERVGNB);
                    servSINR = r(COL_SERVSINR);
                    numVis   = r(COL_NUMVIS);
                    maxN     = safeCol(r, COL_MAXN);
                    meanN    = safeCol(r, COL_MEANN);
                    spread   = safeCol(r, COL_SPREAD);
                    hoCount  = r(COL_HO);
                    tSince   = safeCol(r, COL_TSINCE);
                    gIdx = find([gNBs.ID] == servGNB, 1);
                    if ~isempty(gIdx)
                        gPos = frame(posLog.nodeIDs == servGNB, :);
                        % Serving line, coloured by the LOS state the
                        % simulator actually holds AT THIS INSTANT.
                        % linkState is the same function the channel model
                        % calls, so the colour cannot disagree with the
                        % pathloss branch. For an archived run whose
                        % linkInfo has no spatially-consistent field this
                        % falls back to the frozen setup-time state, and
                        % the annotation says so rather than leaving a
                        % static colour next to a sweeping pLOS.
                        lineSpec = {'b-'};
                        st = [];
                        if hasExtras && isfield(extras,'linkInfo') ...
                                && isfield(extras,'cfg') ...
                                && exist('linkState','file') == 2
                            st = linkState(extras.linkInfo, extras.cfg, ...
                                servGNB, ueID, gPos, uPos);
                            if st.isLOS
                                lineSpec = {'b-'};
                            else
                                lineSpec = {'r--'};
                            end
                        end
                        plot3(ax,[uPos(1) gPos(1)],[uPos(2) gPos(2)], ...
                            [uPos(3) gPos(3)],lineSpec{1},'LineWidth',1.5);
                        % Channel annotation at the line midpoint:
                        % the live LOS state and its Table B-1
                        % probability, the geometric ZoD, and the
                        % Annex B.1.1 Step 5 ZOD offset at the CURRENT
                        % positions.
                        note = linkAnnotation(extras, gPos, uPos, st);
                        if ~isempty(note)
                            mid = (uPos + gPos)/2;
                            text(ax, mid(1), mid(2), mid(3)+5, note, ...
                                'FontSize',7,'Color',lblCol, ...
                                'HorizontalAlignment','center', ...
                                'Interpreter','none');
                        end
                    end
                end
            end

            % Multi-line block per UE; full set of logged statistics
            lines{end+1,1} = sprintf('%s  [%s]', m.UE.Name, m.ueLabel);     %#ok<AGROW>
            lines{end+1,1} = sprintf('   serve gNB%g   SINR %5.1f dB   vis %g', ...
                servGNB, servSINR, numVis);                                  %#ok<AGROW>
            lines{end+1,1} = sprintf('   maxN %5.1f   meanN %5.1f   spread %4.1f', ...
                maxN, meanN, spread);                                        %#ok<AGROW>
            lines{end+1,1} = sprintf('   HO %g   t_sinceHO %.3f s', ...
                hoCount, tSince);                                            %#ok<AGROW>

            % Sliding-window block (Phase 3): the D3.1 windowed features
            % over the trailing winLen seconds, computed live from the
            % same per-scan log the dataset uses. Settle-period scans and
            % handovers are excluded, matching extractWindowedFeatures.
            if hasExtras && ~isempty(fl)
                w0 = t - winLen;
                inW = fl(:,COL_TIME) >= max(w0, settleT) & fl(:,COL_TIME) <= t;
                if any(inW)
                    ws = fl(inW, COL_SERVSINR);
                    hoT = hoLists{k};   % culled/re-zeroed copy
                    hoT = hoT(hoT >= max(w0, settleT) & hoT <= t);
                    if numel(hoT) >= 2
                        interHO = sprintf('%.2f s', mean(diff(hoT)));
                    else
                        interHO = 'n/a';
                    end
                    lines{end+1,1} = sprintf('   win %.1fs: SINR mu %5.1f var %5.2f', ...
                        winLen, mean(ws,'omitnan'), var(ws,0,'omitnan'));    %#ok<AGROW>
                    lines{end+1,1} = sprintf('   win HO %d   interHO %s', ...
                        numel(hoT), interHO);                                %#ok<AGROW>
                elseif t < settleT
                    lines{end+1,1} = sprintf('   win: settle period (< %.1f s)', ...
                        settleT);                                            %#ok<AGROW>
                end
            end
            lines{end+1,1} = '';                                             %#ok<AGROW>
        end

        % Handover event markers (shown once their time has passed)
        if ~isempty(hoEvents)
            past = hoEvents(hoEvents(:,1) <= t, :);
            if ~isempty(past)
                scatter3(ax, past(:,2), past(:,3), past(:,4), 120, 'p', ...
                    'MarkerEdgeColor','k', 'MarkerFaceColor',[1 0.85 0]);
            end
        end
        hold(ax,'off');
        ttl = sprintf('t = %.3f s   (frame %d/%d)', t, fIdx, nFrames);
        if hasExtras
            ttl = sprintf('%s   |   window [%.1f, %.1f] s (gold trail)', ...
                ttl, max(t - winLen, posLog.times(1)), t);
        end
        if t < settleT
            ttl = [ttl '   |   SETTLE (excluded from dataset)'];
        end
        title(ax, ttl);

        header = { sprintf('t = %.3f s', t); ...
                   sprintf('frame %d / %d', fIdx, nFrames); '' };
        readout.Value = [header; lines];
    end
end

% ----------------------------------------------------------------------------
function c = fgColour(ax, fig)
%fgColour Text/mast colour with contrast against the active theme.
%   Reads the axes (or figure) background luminance and returns near-white
%   on dark backgrounds and near-black on light ones, so labels stay
%   readable in both light and dark mode.
    bg = ax.Color;
    if ~isnumeric(bg) || numel(bg) < 3
        bg = fig.Color;
    end
    if ~isnumeric(bg) || numel(bg) < 3
        bg = [1 1 1];
    end
    if mean(bg(1:3)) < 0.5
        c = [0.95 0.95 0.95];
    else
        c = [0.10 0.10 0.10];
    end
end

% ----------------------------------------------------------------------------
function drawBuildings(ax, buildings)
%drawBuildings Draw each axis-aligned building as a translucent grey box.
%   BUILDINGS is N-by-6: [xmin xmax ymin ymax zmin zmax] per row.
    if isempty(buildings), return; end
    F = [1 2 3 4;   % bottom
         5 6 7 8;   % top
         1 2 6 5;   % side
         2 3 7 6;   % side
         3 4 8 7;   % side
         4 1 5 8];  % side
    for b = 1:size(buildings,1)
        xmn = buildings(b,1); xmx = buildings(b,2);
        ymn = buildings(b,3); ymx = buildings(b,4);
        zmn = buildings(b,5); zmx = buildings(b,6);
        V = [xmn ymn zmn; xmx ymn zmn; xmx ymx zmn; xmn ymx zmn; ...
             xmn ymn zmx; xmx ymn zmx; xmx ymx zmx; xmn ymx zmx];
        patch(ax,'Vertices',V,'Faces',F, ...
            'FaceColor',[0.55 0.55 0.55],'FaceAlpha',0.25, ...
            'EdgeColor',[0.30 0.30 0.30],'LineWidth',0.5);
    end
end

% ----------------------------------------------------------------------------
function note = linkAnnotation(extras, gPos, uPos, st)
%linkAnnotation One-line channel summary for a serving link.
%   Computed live at the CURRENT node positions: the LOS state and its
%   Table B-1 / Table 7.4.2-1 probability, the geometric ZoD of the link,
%   and the Annex B.1.1 Step 5 ZOD offset (zero below the z-boundary and
%   for scenarios without a CDL-D offset geometry, i.e. UMi). Returns ''
%   for Phase 2 replays (no extras) or when the Phase 3 helpers are not on
%   the path.
%
%   ST is the linkState struct for this link at this instant, or [] when
%   no link info is available. The state is printed as LOS or NLOS and
%   tagged "frozen" when it came from the setup-time draw rather than the
%   spatially-consistent field, so an archived Phase 4 replay cannot be
%   mistaken for a run whose state simply never happened to change.
%
%   The fast-fading objects were built from the INITIAL geometry and stay
%   static for the run; these values show what the pathloss and state
%   models give at the scrubbed instant.
    note = '';
    if nargin < 4, st = []; end
    if ~isstruct(extras) || ~isfield(extras,'cfg') ...
            || exist('tr36777LOSProbability','file') ~= 2
        return;
    end
    c = extras.cfg;
    dxy = uPos(1:2) - gPos(1:2);
    d2D = max(norm(dxy), 1);
    d3D = max(norm(uPos - gPos), 1);
    hUT = uPos(3);  hBS = gPos(3);
    zodGeo = acosd((hUT - hBS)/d3D);
    pLOS = tr36777LOSProbability(c.scenario, hUT, d2D);
    off = 0;
    if isfield(c,'zBoundary') && hUT > c.zBoundary
        switch upper(string(c.scenario))
            case "RMA"   % eq B.1.1-1, ground reflection
                off = atand((hBS + hUT)/d2D) + atand((hUT - hBS)/d2D);
            case "UMA"   % eq B.1.1-2, rooftop reflection
                off = atand((hBS + hUT - 2*c.avgBuildingHeight)/d2D) + ...
                      atand((hUT - hBS)/d2D);
        end
    end
    band = 'terr';
    if isfield(c,'zBoundary') && hUT > c.zBoundary, band = 'aerial'; end

    state = '';
    if ~isempty(st)
        if st.isLOS, s = 'LOS'; else, s = 'NLOS'; end
        if st.dynamic, tag = ''; else, tag = ' (frozen)'; end
        state = sprintf('%s%s | ', s, tag);
    end

    note = sprintf('%s | %spLOS %.2f | ZoD %.0f deg | ZODoff %.1f deg', ...
        band, state, pLOS, zodGeo, off);
end

% ----------------------------------------------------------------------------
function v = safeCol(rowVec, idx)
%safeCol Return rowVec(idx) or NaN if that column does not exist.
    if numel(rowVec) >= idx
        v = rowVec(idx);
    else
        v = NaN;
    end
end