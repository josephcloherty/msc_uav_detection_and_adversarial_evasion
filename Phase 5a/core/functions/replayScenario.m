function replayScenario(posLog, gNBs, UEs, managers, buildings, extras)
% opens a scrollable 3D replay of a finished run: node positions, serving-cell
% lines, handover markers and a per-timestamp statistics readout.

    % reload mode: a saved .mat path, or no arguments at all
    if nargin <= 1 && (nargin == 0 || ischar(posLog) || isstring(posLog))
        if nargin == 0
            fname = '';
        else
            fname = char(posLog);
        end
        if isempty(fname) || exist(fname,'file') ~= 2
            [f,p] = uigetfile({'*.mat','Saved replay (*.mat)'}, ...
                'Open saved replay');
            if isequal(f,0), return; end   % cancelled
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
        extras = [];              % no channel info
    end

    % window and settle settings from the config
    winLen = 10;  settleT = 0;  hasExtras = isstruct(extras);
    if hasExtras && isfield(extras,'cfg')
        if isfield(extras.cfg,'windowLen'),  winLen  = extras.cfg.windowLen;  end
        if isfield(extras.cfg,'settleTime'), settleT = extras.cfg.settleTime; end
    end

    % featureLog column indices
    COL_TIME    = 1;
    COL_SERVGNB = 4;
    COL_SERVSINR= 5;
    COL_NUMVIS  = 6;
    COL_MAXN    = 7;
    COL_MEANN   = 8;
    COL_SPREAD  = 9;
    COL_HO      = 10;
    COL_TSINCE  = 11;

    % cull the opening seconds and re-zero the clock, so playback starts after
    % the attach and handover burst. the uncoloured originals are kept for saving.
    % older recordings carry a spurious all-zero first frame; drop it
    if size(posLog.xyz, 3) == numel(posLog.times) + 1
        posLog.xyz(:,:,1) = [];
    end

    posLogRaw = posLog;               % saved verbatim
    % the cull is at least the settle span and can only be extended
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

    % local time-shifted copies; the manager objects are never modified
    featLogs = cell(numel(managers),1);
    hoLists  = cell(numel(managers),1);
    sinrLogs = cell(numel(managers),1);   % per-gNB SINR
    for kk = 1:numel(managers)
        flk = managers{kk}.featureLog;
        if ~isempty(flk)
            flk = flk(flk(:,COL_TIME) >= cull, :);
            flk(:,COL_TIME) = flk(:,COL_TIME) - cull;
        end
        featLogs{kk} = flk;
        ht = managers{kk}.handoverTimes(:);
        hoLists{kk} = ht(ht >= cull) - cull;
        % per-gNB SINR log, empty for older saves
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

    % compress the z aspect so altitude is visible
    zAspect = 0.3;

    % layout: axes top left, controls below, readout on the right
    fig = uifigure('Name','Scenario Replay','Position',[100 100 1220 770]);
    g = uigridlayout(fig,[2 2], ...
        'RowHeight',{'1x',60}, 'ColumnWidth',{'1x',360});

    ax = uiaxes('Parent',g);
    ax.Layout.Row = 1; ax.Layout.Column = 1;
    ax.DataAspectRatio = [1 1 zAspect];
    xlabel(ax,'X (m)'); ylabel(ax,'Y (m)'); zlabel(ax,'Z (m)');
    grid(ax,'on'); view(ax,3);

    % readout spans both rows
    readout = uitextarea('Parent',g, 'Editable','off', ...
        'FontName','monospaced', 'FontSize',12);
    readout.Layout.Row = [1 2];
    readout.Layout.Column = 2;

    % controls sit under the axes
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
            'posLog',    posLogRaw, ...   % un-culled
            'gNBs',      gNBs, ...
            'UEs',       UEs, ...
            'managers',  {managers}, ...   % cell wrapped
            'buildings', buildings, ...
            'extras',    extras, ...       % channel and window info
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

    % every series the replay data can support, not only the logged columns
    function names = plottableNames()
        names = { ...
            'servingSINR','maxNeighbourSINR','meanNeighbourSINR', ...
            'sinrMargin','sinrSpread','numVisible','servingGNB', ...
            'handoverCount','timeSinceLastHO','label_is_aerial'};
        for gg = 1:numel(gNBs)                    % per-gNB SINR
            names{end+1} = sprintf('SINR_gNB%d', gNBs(gg).ID); %#ok<AGROW>
        end
        names = [names, {'altitude_m','speed2D_mps','dist2D_serving_m', ...
            'dist3D_serving_m'}];
        for gg = 1:numel(gNBs)                    % per-gNB distance
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
    % returns the time base and values of one derived series, on the culled clock.
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
                % per-gNB series
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
    % returns live geometry towards the current serving cell.
        fl = featLogs{k};
        ueID = managers{k}.UE.ID;
        ts = posLog.times(:);
        ys = nan(numel(ts), 1);
        uTr = squeeze(posLog.xyz(posLog.nodeIDs == ueID, :, :));   % 3 by T
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
                    % the actual state from the same linkState the channel
                    % model used
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
    % returns the sliding-window features evaluated at every scan time, so the
    % plotted curves match what the dataset windows sample.
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
        if n <= 4, nc = 1; else, nc = 2; end      % two columns
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
        if playBtn.Value                  % grabbed mid-playback
            playBtn.Value = false;
            playBtn.Text = 'Play';
            stop(playTimer);
        end
        redraw(tSel);
    end

    % real-time playback
    uiRate = 20;                          % refresh rate, Hz
    playTimer = timer('ExecutionMode','fixedSpacing', ...
        'Period',1/uiRate, 'TimerFcn',@(~,~) playTick());
    lastTic = [];                         % wall-clock anchor

    playBtn.ValueChangedFcn = @(s,~) togglePlay(s.Value);
    fig.CloseRequestFcn = @(~,~) cleanUp();   % stop the timer

    function togglePlay(isPlaying)
        if isPlaying
            playBtn.Text = 'Pause';
            % restart if at the end
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
        dt = toc(lastTic);                % real seconds elapsed
        lastTic = tic;
        tNew = slider.Value + dt;
        if tNew >= posLog.times(end)
            tNew = posLog.times(end);
            playBtn.Value = false;        % auto-pause
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

    % fix the axis limits from the whole history, so the view does not jump
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

    % precompute the handover events
    hoEvents = [];   % time, x, y, z
    for k = 1:numel(managers)
        fl = featLogs{k};   % re-zeroed copy
        if size(fl,1) < 2, continue; end
        hoIdx = find(diff(fl(:,COL_HO)) > 0) + 1;   % count increments
        ueID = managers{k}.UE.ID;
        for j = hoIdx'
            tHO = fl(j,COL_TIME);
            [~,fI] = min(abs(posLog.times - tHO));          % nearest frame
            p = posLog.xyz(posLog.nodeIDs == ueID, :, fI);
            hoEvents(end+1,:) = [tHO p]; %#ok<AGROW>
        end
    end

    redraw(posLog.times(1));   % initial frame

    function redraw(tSel)
        % snap to the nearest logged frame
        [~,fIdx] = min(abs(posLog.times - tSel));
        t = posLog.times(fIdx);
        frame = posLog.xyz(:,:,fIdx);    % N by 3

        cla(ax); hold(ax,'on');
        xlim(ax,xL); ylim(ax,yL); zlim(ax,zL);

        % pick a label colour with contrast against the theme
        lblCol = fgColour(ax, fig);

        % buildings, redrawn each frame because cla wipes
        drawBuildings(ax, buildings);

        % gNBs
        nG = numel(gNBs);
        for i = 1:nG
            gID = gNBs(i).ID;
            gPos = frame(posLog.nodeIDs == gID, :);
            scatter3(ax,gPos(1),gPos(2),gPos(3),90,'^','filled', ...
                'MarkerFaceColor',[0.20 0.40 0.80]);
            % mast down to ground level
            plot3(ax,[gPos(1) gPos(1)],[gPos(2) gPos(2)],[gPos(3) 0], ...
                '-','Color',lblCol,'LineWidth',1.5);
            text(ax,gPos(1),gPos(2),gPos(3)+8,"gNB"+gID, ...
                'FontSize',8,'HorizontalAlignment','center','Color',lblCol);
        end

        % UEs, serving lines and the per-UE readout
        lines = {};
        for k = 1:numel(managers)
            m = managers{k};
            ueID = m.UE.ID;
            uPos = frame(posLog.nodeIDs == ueID, :);
            scatter3(ax,uPos(1),uPos(2),uPos(3),90,'o','filled', ...
                'MarkerFaceColor',[0.85 0.30 0.20]);
            text(ax,uPos(1),uPos(2),uPos(3)+8,m.ueLabel, ...
                'FontSize',8,'HorizontalAlignment','center','Color',lblCol);

            % gold trail over the trailing feature window
            inWin = posLog.times >= (t - winLen) & posLog.times <= t;
            if nnz(inWin) > 1
                tr = squeeze(posLog.xyz(posLog.nodeIDs == ueID, :, inWin));
                plot3(ax, tr(1,:), tr(2,:), tr(3,:), '-', ...
                    'Color', [0.95 0.75 0.10], 'LineWidth', 2);
                scatter3(ax, tr(1,1), tr(2,1), tr(3,1), 40, 'o', ...
                    'MarkerEdgeColor', [0.95 0.75 0.10], 'LineWidth', 1.5);
            end

            % latest feature row at or before the current time
            servGNB = NaN; servSINR = NaN; numVis = NaN; maxN = NaN; ...
                meanN = NaN; spread = NaN; hoCount = NaN; tSince = NaN;
            fl = featLogs{k};   % re-zeroed copy
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
                        % colour the serving line by the state linkState
                        % reports at this instant
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
                        % channel annotation at the line midpoint
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

            % one block per UE
            lines{end+1,1} = sprintf('%s  [%s]', m.UE.Name, m.ueLabel);     %#ok<AGROW>
            lines{end+1,1} = sprintf('   serve gNB%g   SINR %5.1f dB   vis %g', ...
                servGNB, servSINR, numVis);                                  %#ok<AGROW>
            lines{end+1,1} = sprintf('   maxN %5.1f   meanN %5.1f   spread %4.1f', ...
                maxN, meanN, spread);                                        %#ok<AGROW>
            lines{end+1,1} = sprintf('   HO %g   t_sinceHO %.3f s', ...
                hoCount, tSince);                                            %#ok<AGROW>

            % sliding-window block over the trailing winLen seconds,
            % excluding settle scans as the dataset does
            if hasExtras && ~isempty(fl)
                w0 = t - winLen;
                inW = fl(:,COL_TIME) >= max(w0, settleT) & fl(:,COL_TIME) <= t;
                if any(inW)
                    ws = fl(inW, COL_SERVSINR);
                    hoT = hoLists{k};   % re-zeroed copy
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

        % handover markers, shown once their time has passed
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

function c = fgColour(ax, fig)
% returns a text colour with contrast against the active theme, so labels stay
% readable in light and dark mode.
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

function drawBuildings(ax, buildings)
% draws each axis-aligned building as a translucent grey box.
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

function note = linkAnnotation(extras, gPos, uPos, st)
% returns a one-line channel summary for a serving link, computed live at the
% current node positions.
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
            case "RMA"   % ground reflection
                off = atand((hBS + hUT)/d2D) + atand((hUT - hBS)/d2D);
            case "UMA"   % rooftop reflection
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

function v = safeCol(rowVec, idx)
% returns rowVec(idx), or NaN when that column does not exist.
    if numel(rowVec) >= idx
        v = rowVec(idx);
    else
        v = NaN;
    end
end