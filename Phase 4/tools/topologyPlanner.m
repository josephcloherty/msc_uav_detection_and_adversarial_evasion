%% geometryPlanner.m
% Static 3D geometry planner for the C-UAS scenario.
%
% Edit the three blocks below, then press Run (the green Play button) to open
% an interactive 3D viewer. Drag with the mouse to orbit; scroll to zoom.
% No simulator and no mobility are involved: this shows only where the gNBs,
% UEs, and buildings sit, so the layout can be planned in isolation.
%
% The matrices use the SAME names and formats as the main scenario script,
% so once the layout looks right the three blocks can be pasted straight
% across with no conversion.

clc; clear; close all;

spacing = 325;
%% gNB positions  [x y z]   (z is mast height)
gNBPositions = [ ...
    %spacing  2*spacing  25; % top right
    %0  2*spacing  25; % top left
    %spacing/2+spacing  spacing  25; % middle right
    %spacing/2-spacing  spacing  25; % middle left
    %spacing/2  spacing  25; % middle middle
    spacing  0  25; % bottom right
    0  0  25]; % bottom left

%% UE positions   [x y z]   (z above aerialAltThresh is treated as aerial)
uePositions = [ ...
    -6 100 1.5; % Terrestrial
    -32 20 1.5;
    80 350 1.5;
    122 220 1.5;
    110 413 1.5;
     200 0  100]; % Aerial
aerialAltThresh = 10;     % metres; a UE above this is drawn as aerial

%% Buildings      [xCentre yCentre xWidth yWidth height]
buildingsRaw = [ ...
    150 0 40 60 80;
    150 80 40 60 55;
    150 160 40 60 35;
    150 240 40 60 90;
    200 300 100 40 30;
    -40 300 60 40 45;
    40 300 60 40 35;
    120 300 60 40 60;
    -100 0 40 60 70;
    -100 80 40 60 35;
    -100 160 40 60 45;
    -100 240 40 60 30];      % add one row per building

% Convert to axis-aligned extents [xmin xmax ymin ymax zmin zmax].
% Same conversion as the scenario script, kept here so the planner is
% self-contained.
if isempty(buildingsRaw)
    buildingsAABB = zeros(0,6);
else
    buildingsAABB = [ ...
        buildingsRaw(:,1)-buildingsRaw(:,3)/2, buildingsRaw(:,1)+buildingsRaw(:,3)/2, ...
        buildingsRaw(:,2)-buildingsRaw(:,4)/2, buildingsRaw(:,2)+buildingsRaw(:,4)/2, ...
        zeros(size(buildingsRaw,1),1),         buildingsRaw(:,5)];
end

%% Mobility bounds  [xcentre ycentre length width]  (centre + size — matches addMobility)
% Same convention as addMobility's "rectangle" Bounds, so these rows paste
% straight into the scenario with no conversion. Values updated from the old
% origin+size form: [150 350 1100 1200] here is the exact same box that
% [-400 -250 1100 1200] drew under the previous origin+size interpretation.
terrBounds = [150 350 1100 1200];     % terrestrial roaming box
aerBounds  = [150 350 1100 1200];     % aerial roaming box
%% Display options
cellRadius = 500;    % ground footprint circle radius per gNB (0 disables)
zAspect    = 1;    % Z-axis exaggeration (smaller makes height more visible)

%% ---- render ----
planGeometry(gNBPositions, uePositions, aerialAltThresh, ...
    buildingsAABB, cellRadius, zAspect, terrBounds, aerBounds);

% Console summary for quick sanity checking
nAerial = sum(uePositions(:,3) > aerialAltThresh);
fprintf('Geometry: %d gNBs | %d UEs (%d aerial, %d terrestrial) | %d buildings\n', ...
    size(gNBPositions,1), size(uePositions,1), nAerial, ...
    size(uePositions,1)-nAerial, size(buildingsRaw,1));


%% ========================================================================
function planGeometry(gNBPos, uePos, aerialAltThresh, buildings, cellRadius, zAspect, terrBounds, aerBounds)
%planGeometry Draw a static 3D layout of gNBs, UEs and buildings.

    fig = figure('Name','Geometry Planner','Color','w', ...
        'Position',[100 100 1100 760]);
    ax = axes('Parent',fig); hold(ax,'on'); grid(ax,'on');
    ax.DataAspectRatio = [1 1 zAspect];
    xlabel(ax,'X (m)'); ylabel(ax,'Y (m)'); zlabel(ax,'Z (m)');
    view(ax,3);

    legHandles = gobjects(0); legLabels = strings(0);

    % --- gNB footprint circles at ground level ---
    if cellRadius > 0
        th = linspace(0,2*pi,121);
        hFoot = gobjects(0);
        for i = 1:size(gNBPos,1)
            xc = cellRadius*cos(th) + gNBPos(i,1);
            yc = cellRadius*sin(th) + gNBPos(i,2);
            hFoot = plot3(ax, xc, yc, zeros(size(xc)), ...
                'Color',[0.7 0.7 0.7], 'LineStyle','--', 'LineWidth',0.75);
        end
        legHandles(end+1) = hFoot; legLabels(end+1) = "Cell footprint";
    end
    % --- mobility bounds drawn as ground rectangles ([x y w h]) ---
    hTerrB = drawBounds(ax, terrBounds, [0.20 0.65 0.30]);
    if ~isempty(hTerrB)
        legHandles(end+1) = hTerrB; legLabels(end+1) = "Terrestrial bounds";
    end
    hAerB = drawBounds(ax, aerBounds, [0.85 0.30 0.20]);
    if ~isempty(hAerB)
        legHandles(end+1) = hAerB; legLabels(end+1) = "Aerial bounds";
    end
    % --- buildings as translucent boxes ---
    hBuild = drawBuildings(ax, buildings);
    if ~isempty(hBuild)
        legHandles(end+1) = hBuild; legLabels(end+1) = "Building";
    end

    % --- gNBs: triangle markers with masts to ground ---
    hG = scatter3(ax, gNBPos(:,1), gNBPos(:,2), gNBPos(:,3), 110, '^', ...
        'filled', 'MarkerFaceColor',[0.20 0.40 0.80], 'MarkerEdgeColor','k');
    legHandles(end+1) = hG; legLabels(end+1) = "gNB";
    for i = 1:size(gNBPos,1)
        plot3(ax, [gNBPos(i,1) gNBPos(i,1)], [gNBPos(i,2) gNBPos(i,2)], ...
            [gNBPos(i,3) 0], 'Color',[0.20 0.40 0.80], 'LineWidth',1.0);
        text(ax, gNBPos(i,1), gNBPos(i,2), gNBPos(i,3)+10, "gNB-"+i, ...
            'HorizontalAlignment','center', 'FontSize',8, 'FontWeight','bold');
    end

    % --- UEs: split into terrestrial and aerial ---
    isAerial = uePos(:,3) > aerialAltThresh;

    terr = uePos(~isAerial,:);
    if ~isempty(terr)
        hT = scatter3(ax, terr(:,1), terr(:,2), terr(:,3), 90, 'o', ...
            'filled', 'MarkerFaceColor',[0.20 0.65 0.30], 'MarkerEdgeColor','k');
        legHandles(end+1) = hT; legLabels(end+1) = "UE (terrestrial)";
    end

    aer = uePos(isAerial,:);
    if ~isempty(aer)
        hA = scatter3(ax, aer(:,1), aer(:,2), aer(:,3), 130, 'p', ...
            'filled', 'MarkerFaceColor',[0.85 0.30 0.20], 'MarkerEdgeColor','k');
        legHandles(end+1) = hA; legLabels(end+1) = "UE (aerial)";
        % Drop-lines to ground so aerial XY position is readable
        for i = 1:size(aer,1)
            plot3(ax, [aer(i,1) aer(i,1)], [aer(i,2) aer(i,2)], ...
                [aer(i,3) 0], 'Color',[0.85 0.30 0.20], ...
                'LineStyle',':', 'LineWidth',0.75);
        end
    end

    % UE name labels in original row order
    for i = 1:size(uePos,1)
        text(ax, uePos(i,1), uePos(i,2), uePos(i,3)+10, "UE-"+i, ...
            'HorizontalAlignment','center', 'FontSize',8);
    end

    % --- axis limits spanning nodes, buildings and footprints ---
    xs = [gNBPos(:,1); uePos(:,1)];
    ys = [gNBPos(:,2); uePos(:,2)];
    zs = [gNBPos(:,3); uePos(:,3); 0];
    if ~isempty(buildings)
        xs = [xs; buildings(:,1); buildings(:,2)];
        ys = [ys; buildings(:,3); buildings(:,4)];
        zs = [zs; buildings(:,6)];
    end
    if cellRadius > 0
        xs = [xs; gNBPos(:,1)-cellRadius; gNBPos(:,1)+cellRadius];
        ys = [ys; gNBPos(:,2)-cellRadius; gNBPos(:,2)+cellRadius];
    end
    pad = 40;
    xlim(ax, [min(xs)-pad, max(xs)+pad]);
    ylim(ax, [min(ys)-pad, max(ys)+pad]);
    zlim(ax, [0, max(zs)+pad]);

    legend(ax, legHandles, legLabels, 'Location','northeastoutside', ...
        'AutoUpdate','off');
    title(ax, 'Scenario geometry (drag to orbit, scroll to zoom)');

    rotate3d(ax, 'on');   % interactive orbit
    % include mobility bounds so the rectangles are never clipped (centre + size)
    for B = {terrBounds, aerBounds}
        Bi = B{1};
        if ~isempty(Bi)
            xs = [xs; Bi(:,1)-Bi(:,3)/2; Bi(:,1)+Bi(:,3)/2];
            ys = [ys; Bi(:,2)-Bi(:,4)/2; Bi(:,2)+Bi(:,4)/2];
        end
    end
end

%% ========================================================================
function h = drawBuildings(ax, buildings)
%drawBuildings Draw each axis-aligned building as a translucent grey box.
%   BUILDINGS is N-by-6: [xmin xmax ymin ymax zmin zmax] per row.
%   Returns a handle to the last box for legend use (empty if none).
    h = gobjects(0);
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
        h = patch(ax, 'Vertices',V, 'Faces',F, ...
            'FaceColor',[0.55 0.55 0.55], 'FaceAlpha',0.25, ...
            'EdgeColor',[0.30 0.30 0.30], 'LineWidth',0.5);
    end
end
function h = drawBounds(ax, B, colour)
%drawBounds Draw a mobility rectangle given [xcentre ycentre length width] at z = 0.
%   Matches addMobility's "rectangle" Bounds convention (centre + size).
    h = gobjects(0);
    if isempty(B), return; end
    for r = 1:size(B,1)
        xc = B(r,1); yc = B(r,2); w = B(r,3); hgt = B(r,4);
        x0 = xc - w/2;  y0 = yc - hgt/2;
        X = [x0, x0+w, x0+w, x0,   x0];
        Y = [y0, y0,   y0+hgt, y0+hgt, y0];
        h = plot3(ax, X, Y, zeros(size(X)), ...
            'Color', colour, 'LineStyle','-', 'LineWidth',1.25);
    end
end