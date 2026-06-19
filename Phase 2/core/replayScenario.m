function replayScenario(posLog, gNBs, UEs, managers, buildings)
%replayScenario Post-run 3D scrollable replay of node positions with
% serving-cell lines, building geometry, and per-timestamp statistics.
%
%   replayScenario(POSLOG, GNBS, UES, MANAGERS)
%   replayScenario(POSLOG, GNBS, UES, MANAGERS, BUILDINGS)
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
        replayScenario(d.posLog, d.gNBs, d.UEs, d.managers, bld);
        return;
    end

    if nargin < 5 || isempty(buildings)
        buildings = zeros(0,6);   % no buildings
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
            'posLog',    posLog, ...
            'gNBs',      gNBs, ...
            'UEs',       UEs, ...
            'managers',  {managers}, ...   % cell wrapped to keep as one field
            'buildings', buildings, ...
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

    % ---- Plot selected feature variables over time -------------------------
    % Variable names come straight from the handover manager's featureNames so
    % the selectable list always matches what was logged. "time" is the X axis
    % and is therefore excluded from the choices.
    function names = plottableNames()
        names = {};
        for kk = 1:numel(managers)
            if ~isempty(managers{kk}.featureNames)
                names = managers{kk}.featureNames;
                break;
            end
        end
        if isempty(names)
            % Fallback to the documented column order
            names = {'time','ueID','label_is_aerial','servingGNB', ...
                'servingSINR','numVisible','maxNeighbourSINR', ...
                'meanNeighbourSINR','sinrSpread','handoverCount', ...
                'timeSinceLastHO'};
        end
        names = names(~ismember(names, {'time'}));   % time is the X axis
    end

    function plotFiguresDialog()
        names = plottableNames();
        if isempty(names)
            uialert(fig,'No logged variables available to plot.', ...
                'Nothing to plot','Icon','warning');
            return;
        end
        dlg = uifigure('Name','Plot variables over time', ...
            'Position',[200 200 320 380]);
        gl = uigridlayout(dlg,[3 1],'RowHeight',{20,'1x',32});
        uilabel(gl,'Text','Select one or more variables:');
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
        f = figure('Name','Replay - selected variables over time');
        for s = 1:n
            ax2 = subplot(n,1,s); hold(ax2,'on');
            vname = selNames{s};
            for k = 1:numel(managers)
                m = managers{k};
                fl = m.featureLog;
                if isempty(fl) || isempty(m.featureNames), continue; end
                ti = find(strcmp(m.featureNames,'time'),1);
                ci = find(strcmp(m.featureNames,vname),1);
                if isempty(ti) || isempty(ci), continue; end
                plot(ax2, fl(:,ti), fl(:,ci), 'DisplayName', m.ueLabel);
            end
            ylabel(ax2, vname, 'Interpreter','none');
            grid(ax2,'on'); legend(ax2,'show');
            if s == 1
                title(ax2,'Feature time series (replay)');
            end
            if s == n
                xlabel(ax2,'Time (s)');
            end
        end
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
        fl = managers{k}.featureLog;
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
                'w-','LineWidth',1.5);
            text(ax,gPos(1),gPos(2),gPos(3)+8,"gNB"+gID, ...
                'FontSize',8,'HorizontalAlignment','center');
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
                'FontSize',8,'HorizontalAlignment','center');

            % Latest feature row at or before current time
            servGNB = NaN; servSINR = NaN; numVis = NaN; maxN = NaN; ...
                meanN = NaN; spread = NaN; hoCount = NaN; tSince = NaN;
            fl = m.featureLog;
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
                        plot3(ax,[uPos(1) gPos(1)],[uPos(2) gPos(2)], ...
                            [uPos(3) gPos(3)],'b-','LineWidth',1.5);
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
        title(ax,sprintf('t = %.3f s   (frame %d/%d)', t, fIdx, nFrames));

        header = { sprintf('t = %.3f s', t); ...
                   sprintf('frame %d / %d', fIdx, nFrames); '' };
        readout.Value = [header; lines];
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
function v = safeCol(rowVec, idx)
%safeCol Return rowVec(idx) or NaN if that column does not exist.
    if numel(rowVec) >= idx
        v = rowVec(idx);
    else
        v = NaN;
    end
end