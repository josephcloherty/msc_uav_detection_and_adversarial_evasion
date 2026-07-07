classdef helperNetworkVisualizer < handle
    %helperNetworkVisualizer Show the network visualization in 3D
    %   VISOBJ = helperNetworkVisualizer creates a network visualization object.
    %
    %   VISOBJ = helperNetworkVisualizer(Name=Value) creates a network
    %   visualization object, VISOBJ, with the specified property Name set to
    %   the specified Value. You can specify additional name-value arguments in
    %   any order as (Name1=Value1, ...,NameN=ValueN)
    %
    %   helperNetworkVisualizer properties (configurable through N-V pair only):
    %
    %   Axis        - Axis of the figure object on which network should be visualized
    %   SampleRate  - Mobility refresh rate in terms of Hz
    %
    %   helperNetworkVisualizer methods:
    %
    %   showBoundaries               - Display the boundaries as circles (ground footprints)
    %   showBuildings                - Display buildings as translucent 3D boxes
    %   showInfrastructureGridLayout - Display the infrastructure grid
    %   addNodes                     - Add nodes to network visualization
    %
    %   This version renders the scenario in 3D. Node positions use their full
    %   [x y z] coordinate, so gNB mast height and UE altitude are shown on the
    %   Z axis. Cell boundaries are drawn as ground footprints at z = 0.

    %   Copyright 2023 The MathWorks, Inc.
    %   Modified for 3D rendering.

    properties (SetAccess=private)
        %Axis Axis of the figure object on which network should be visualized
        Axis

        %SampleRate Mobility refresh rate in terms of Hz
        SampleRate
    end

    properties %(Hidden)
        %Nodes List of nodes in the network
        Nodes

        %Tags Tags of the nodes
        Tags

        %NetworkSimulator Custom network simulator
        NetworkSimulator

        %ShowDatatip Flag to control whether to show the data tips or not
        ShowDatatip = true;

        %ZAspect Z-axis data-aspect compression factor. The X-Y span of the
        % scenario (hundreds of metres) dwarfs the altitude range (tens of
        % metres), so the Z axis is scaled to keep height visible. Set to 1
        % for true equal aspect, or smaller (e.g. 0.3) to exaggerate height.
        ZAspect = 0.3;

        %MarkerColor Color codes for the markers
        MarkerColor = ["--mw-graphics-colorOrder-2-primary" "--mw-borderColor-primary" "--mw-color-teal600" "--mw-color-brown800"]

        %Markers Markers to represent the nodes
        Markers= ["^" "o" "square" "hexagram" "pentagram" "diamond" "|"];

        %NodeMarkerMap Map to track the marker type and its color for nodes
        NodeMarkerMap
    end

    properties %(Access=private)
        %ColorIndex Tracks the currently used colors
        ColorIndex = 0;

        %MarkerIndex Tracks the currently used markers
        MarkerIndex = 0

        %Legend Holds the legend information for the visualization
        Legend = cell(0,2);

        %NumVisualizationUpdate Number of times visualization updates
        NumVisualizationUpdate = 10;
    end

    methods
        function obj = helperNetworkVisualizer(varargin)

            % Name-value pair check
            coder.internal.errorIf(mod(nargin, 2) == 1,'MATLAB:system:invalidPVPairs');

            % Assign the values to parameters
            for idx = 1:2:length(varargin)
                obj.(char(varargin{idx})) = varargin{idx+1};
            end
            obj.Nodes = [];
            obj.Tags = [];
            obj.NodeMarkerMap = containers.Map();
            if isempty(obj.Axis)
                % Using the screen width and height, calculate the figure width and height
                resolution = get(0, 'ScreenSize');
                screenWidth = resolution(3);
                screenHeight = resolution(4);
                figureWidth = screenWidth * 0.75;
                figureHeight =screenHeight * 0.75;
                fig = uifigure(Name="Network Layout Visualization", ...
                    Position=[screenWidth * 0.05 screenHeight * 0.05 figureWidth figureHeight]);
                % Use desktop theme to support dark theme mode
                matlab.graphics.internal.themes.figureUseDesktopTheme(fig);
                g = uigridlayout(fig, [1 1]);
                obj.Axis = uiaxes(Parent=g);
            end
            obj.Axis.XLimMode = 'auto';
            obj.Axis.YLimMode = 'auto';
            obj.Axis.ZLimMode = 'auto';
            obj.Axis.XLabel.String = "X-axis (Meters)";
            obj.Axis.YLabel.String = "Y-axis (Meters)";
            obj.Axis.ZLabel.String = "Z-axis (Meters)";
            % Set a 3D view so altitude is visible from the start
            view(obj.Axis, 3);
            grid(obj.Axis, 'on');

            if isempty(obj.NetworkSimulator)
                obj.NetworkSimulator = wirelessNetworkSimulator.getInstance();% global network simulator
            end
            drawnow;
            scheduleAction(obj.NetworkSimulator, @obj.init, [], 0);% initialise at sim time 0
        end

        function showInfrastructureGridLayout(obj, bsCoordinates, interSiteDistance)
            %showInfrastructureGridLayout Displays the infrastructure grid
            %
            %   showInfrastructureGridLayout (OBJ, BSCOORDINATES, INTERSITEDISTANCE)
            %   Displays an infrastructure grid layout
            %
            %   BSCOORDINATES     - 3D Cartesian coordinates of base station (BS)
            %   INTERSITEDISTANCE - Distance between two adjacent BSs (in meters)

            if ~isvalid(obj.Axis)
                return;
            end

            narginchk(3, 3);
            numBS = size(bsCoordinates,1);
            ax = obj.Axis;
            colors = ["--mw-graphics-colorOrder-2-primary", "--mw-color-selected-noFocus"];
            import matlab.graphics.internal.themes.specifyThemePropertyMappings
            ax.DataAspectRatio = [1 1 obj.ZAspect];
            hold (ax,'on');

            cellSide = interSiteDistance/sqrt(3);
            % Vertices of the polygon that forms the boundary of a cell
            vx = cellSide*cosd(0:60:360); % x coordinates
            vy = cellSide*sind(0:60:360); % y coordinates

            % Plot the network layout. Hexagon footprints are drawn at ground
            % level (z = 0) using plot3.
            for j = 1:numBS
                % Calculate vertices of hexagonal cell
                verticesXCoordinates = bsCoordinates(j,1)+vx;
                verticesYCoordinates = bsCoordinates(j,2)+vy;
                verticesZCoordinates = zeros(size(verticesXCoordinates));

                % Plot cell-site
                cellBoundary = plot3(ax,verticesXCoordinates,verticesYCoordinates, ...
                    verticesZCoordinates,Tag="Cell"+(j));
                specifyThemePropertyMappings(cellBoundary,Color=colors(2));
            end

            hold (ax,'off');
        end

        function showBoundaries(obj, bsCoordinates, cellRadius, varargin)
            %showBoundaries Show the boundaries as circles (ground footprints)
            %
            %   showBoundaries(BSCOORDINATES, CELLRADIUS) Show the boundaries as
            %   circles at ground level (z = 0).
            %
            %   showBoundaries(BSCOORDINATES, CELLRADIUS, CELLOFINTEREST) Show the
            %   boundaries as circles and highlights the cell which has the
            %   CELLOFINTEREST as cell ID.
            %
            %   BSCOORDINATES  - 3D Cartesian coordinates of base station (BS)
            %   CELLRADIUS     - Radius of each cell (in meters)
            %   CELLOFINTEREST - Cell of interest in the given scenario.

            if ~isvalid(obj.Axis)
                return;
            end
            narginchk(3,4);
            numBS = size(bsCoordinates,1);
            ax = obj.Axis;
            % Get the cell of interest index
            cellOfInterest = [];
            if ~isempty(varargin)
                cellOfInterest = varargin{1};%(Su)
                if ~isvector(cellOfInterest) || any(cellOfInterest > numBS)
                    return;
                end
            end

            import matlab.graphics.internal.themes.specifyThemePropertyMappings
            ax.DataAspectRatio = [1 1 obj.ZAspect];
            hold (ax,'on');

            isLegendAdded = false;
            % Plot the network. Circles are drawn as ground footprints at z = 0.
            for i = 1:numBS
                bx = bsCoordinates(i,1); % BS X-coordinate
                by = bsCoordinates(i,2); % BS Y-coordinate
                % Plot the circle representing each cell
                th = 0:pi/60:2*pi;
                x = cellRadius*cos(th)+bx;
                y = cellRadius*sin(th)+by;
                z = zeros(size(x));   % ground level
                cellBoundary = plot3(ax,x,y,z,Tag="Cell"+(i));
                if ismember(i, cellOfInterest)% mark the cell of interest with a distinct colour
                    specifyThemePropertyMappings(cellBoundary,Color="--mw-graphics-colorOrder-5-primary");
                    numItems = size(obj.Legend, 1)+1;
                    obj.Legend{numItems,1} = cellBoundary;
                    obj.Legend{numItems,2} = "Cell of interest";
                else
                    specifyThemePropertyMappings(cellBoundary,Color="--mw-color-selected-noFocus");
                    if ~isLegendAdded
                        isLegendAdded = true;
                        numItems = size(obj.Legend, 1)+1;
                        obj.Legend{numItems,1} = cellBoundary;
                        obj.Legend{numItems,2} = "Interfering cells";
                    end
                end
            end
            hold (ax,'off');
        end

        function showBuildings(obj, buildings)
            %showBuildings Draw buildings as translucent 3D boxes
            %
            %   showBuildings(OBJ, BUILDINGS) draws each building as an
            %   axis-aligned translucent box at its true height.
            %
            %   BUILDINGS - N-by-6 matrix, one row per building, columns
            %               [xmin xmax ymin ymax zmin zmax]. This is the same
            %               buildingsAABB matrix produced in the scenario
            %               script, so adding a building there propagates here
            %               with no further edits.

            if ~isvalid(obj.Axis) || isempty(buildings)
                return;
            end
            ax = obj.Axis;
            import matlab.graphics.internal.themes.specifyThemePropertyMappings
            ax.DataAspectRatio = [1 1 obj.ZAspect];
            hold (ax,'on');

            % Faces of a cuboid given 8 ordered vertices
            F = [1 2 3 4;   % bottom
                 5 6 7 8;   % top
                 1 2 6 5;   % side
                 2 3 7 6;   % side
                 3 4 8 7;   % side
                 4 1 5 8];  % side

            isLegendAdded = false;
            for b = 1:size(buildings,1)
                xmn = buildings(b,1); xmx = buildings(b,2);
                ymn = buildings(b,3); ymx = buildings(b,4);
                zmn = buildings(b,5); zmx = buildings(b,6);
                V = [xmn ymn zmn; xmx ymn zmn; xmx ymx zmn; xmn ymx zmn; ...
                     xmn ymn zmx; xmx ymn zmx; xmx ymx zmx; xmn ymx zmx];
                p = patch(ax,'Vertices',V,'Faces',F, ...
                    'FaceColor',[0.55 0.55 0.55],'FaceAlpha',0.25, ...
                    'EdgeColor',[0.30 0.30 0.30],'LineWidth',0.5, ...
                    'Tag',"Building"+b);
                if ~isLegendAdded
                    isLegendAdded = true;
                    numItems = size(obj.Legend, 1)+1;
                    obj.Legend{numItems,1} = p;
                    obj.Legend{numItems,2} = "Buildings";
                end
            end

            % Refresh the legend so buildings appear regardless of call order
            if ~isempty(obj.Legend)
                legend(ax,[obj.Legend{:,1}], [obj.Legend{:,2}], 'AutoUpdate','off');
            end
            hold (ax,'off');
        end

        function addNodes(obj, nodes, varargin)
            %addNodes Add the nodes on the network visualization
            %
            %   addNodes(OBJ, NODES) adds the specified wireless nodes, NODES, to the
            %   helperNetworkVisualizer object, OBJ. You must add the nodes to the
            %   simulator before running the simulation. Specify NODES as one of these
            %   options.
            %       - A vector of objects of type bluetoothLENode object, bluetoothNode
            %       object, wlanNode object, nrGNB object, nrUE object, hTDMANode object
            %       or any other wirelessnode object.
            %       - A cell array, where each cell can contain a bluetoothLENode
            %       object, bluetoothNode object, wlanNode object, nrGNB object, nrUE
            %       object, hTDMANode object or any other wirelessnode object.
            %
            %   addNodes(OBJ, ..., Name=Value) adds the specified wireless
            %   nodes to the network using parameters specified in name-value
            %   arguments.
            %   Tag - Tag values corresponding to the nodes.

            import matlab.graphics.internal.themes.specifyThemePropertyMappings
            hold (obj.Axis,'on');

            if ~iscell(nodes)
                nodes = num2cell(nodes);
            end

            names = varargin(1:2:end);
            % Search the presence of 'Tag' N-V argument to
            % calculate the number of nodes user intends to plot
            tagIdx = find(strcmp([names{:}], 'Tag'), 1, 'last');
            if isempty(tagIdx)% if no 'Tag' supplied, use node IDs
                nodeTags = string(cellfun( @(x) x.ID, nodes, 'uni', 1));
            else
                nodeTags = varargin{2*tagIdx};
            end

            nodeCoordinates = cell(numel(nodeTags),1);
            for idx=1:numel(nodeTags)
                nodeCoordinates{idx} = nodes{idx}.Position;
                obj.Nodes{end+1} = nodes{idx};
                obj.Tags{end+1} = nodeTags(idx);
            end

            % Validate the tags
            if ~isempty(obj.Tags) && numel(unique(nodeTags)) ~= numel(nodeTags) ...
                    && ~isempty(intersect([obj.Tags{:}], nodeTags))
                error('Nodes IDs/tags must be unique')
            end

            % Plot node(s) in 3D
            for idx = 1:numel(nodeTags)
                px = nodes{idx}.Position(1); % Node X-coordinate
                py = nodes{idx}.Position(2); % Node Y-coordinate
                pz = nodes{idx}.Position(3); % Node Z-coordinate (altitude)
                objectType = string(class(nodes{idx}));
                newType = 0;
                % Find the marker and its color for the new node type
                if ~obj.NodeMarkerMap.isKey(objectType)
                    numMarkers = numel(obj.Markers);
                    numColors = numel(obj.MarkerColor);
                    obj.MarkerIndex = mod(obj.MarkerIndex, numMarkers)+1;
                    obj.ColorIndex = mod(obj.ColorIndex, numColors)+1;
                    obj.NodeMarkerMap(objectType) = [obj.MarkerIndex obj.ColorIndex];
                    newType = 1;
                    if obj.NodeMarkerMap.Count > numMarkers*numColors
                        error("Visualization supports a maximum of '%d' node types", numMarkers*numColors);
                    end
                end

                nodeMarkerInfo = obj.NodeMarkerMap(objectType);
                node = scatter3(obj.Axis, ...
                    px, ...
                    py, ...
                    pz, ...
                    Marker=obj.Markers{nodeMarkerInfo(1)}, ...
                    LineWidth=4, ...
                    Tag=nodeTags(idx));% scatter3 plots the node; later updates only change XData/YData/ZData

                if objectType=='nrGNB' % draw a mast from the gNB marker straight down to ground level (z = 0)
                    line(obj.Axis, ...
                        [px, px], ...
                        [py, py], ...
                        [pz, 0], ...
                        'Color', 'white', 'LineWidth', 1.5, 'Tag', 'gNBMast');
                end

                if objectType=='nrUE' % draw the line between the UE and its serving gNB
                    UEnode=nodes{idx};
                    gNB = UEnode.GNBNodeID; % ID of the gNB this UE is connected to

                    if ~isempty(gNB)
                        gNBPosition = obj.Nodes{gNB}.Position;
                        line(obj.Axis, ...
                            [px, gNBPosition(1)], ...
                            [py, gNBPosition(2)], ...
                            [pz, gNBPosition(3)], ...
                            'Color', 'blue', 'LineWidth', 1.5,'Tag','ConnectionLine');
                    end
                end

                if obj.ShowDatatip  % hover readout, now including Z
                    cellIdRow = dataTipTextRow("", nodes{idx}.Name);
                    posRow = dataTipTextRow('Position[X, Y, Z]: ', ...
                        {sprintf('%.2f, %.2f, %.2f',px,py,pz)});
                    node.DataTipTemplate.DataTipRows = [cellIdRow posRow];
                end
                % Track the new node types
                if newType
                    numItems = size(obj.Legend, 1)+1;
                    obj.Legend{numItems,1} = node;
                    obj.Legend{numItems,2} = objectType;% legend
                end
                % Specify the node color mapping for the current theme
                specifyThemePropertyMappings(node,MarkerFaceColor=obj.MarkerColor{nodeMarkerInfo(2)});
                specifyThemePropertyMappings(node,MarkerEdgeColor=obj.MarkerColor{nodeMarkerInfo(2)});
            end

            legend([obj.Legend{:,1}], [obj.Legend{:,2}], 'AutoUpdate','off');
            hold (obj.Axis,'off');
        end
    end

    methods(Hidden)
        function init(obj,varargin)
            %init Initialize the network visualization

            if isempty(obj.Nodes)
                addNodes(obj, obj.NetworkSimulator.Nodes);
            end

            if isempty(obj.SampleRate) % SampleRate defines the refresh rate
                obj.SampleRate = obj.NumVisualizationUpdate/obj.NetworkSimulator.EndTime;
            end
            scheduleAction(obj.NetworkSimulator, @obj.visualizer, [], 1/obj.SampleRate, 1/obj.SampleRate); % periodic redraw

            drawnow;
        end

        function visualizer(obj, varargin)
            %visualizer Update the node positions in the 3D network visualization
            numTags = numel(obj.Tags);
            delete(findobj(obj.Axis.Children, 'Tag', 'ConnectionLine'));% remove previous serving lines

            for idx=1:numTags
                if ~isvalid(obj.Axis)
                    return;
                end
                nodeDetails = findobj(obj.Axis.Children,'Tag',obj.Tags{idx});% update node position
                position = obj.Nodes{idx}.Position;
                nodeDetails.XData = position(1);
                nodeDetails.YData = position(2);
                nodeDetails.ZData = position(3);

                if obj.ShowDatatip
                    nodeDetails.DataTipTemplate.DataTipRows(2).Value = ...
                        {sprintf('%.2f, %.2f, %.2f',position(1),position(2),position(3))};
                end

                if isa(obj.Nodes{idx}, 'nrUE')
                    % Draw connection line to its gNB in 3D
                    UEnode = obj.Nodes{idx};
                    gNB = UEnode.GNBNodeID; % ID of the gNB this UE is connected to

                    if ~isempty(gNB)
                        gNBPosition = obj.Nodes{gNB}.Position;
                        line(obj.Axis, ...
                            [position(1), gNBPosition(1)], ...
                            [position(2), gNBPosition(2)], ...
                            [position(3), gNBPosition(3)], ...
                            'Color', 'blue', 'LineWidth', 1.5,'Tag','ConnectionLine');
                    end
                end

            end
            drawnow;
        end
    end
end