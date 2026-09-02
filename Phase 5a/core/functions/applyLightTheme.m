function fig = applyLightTheme(fig)
% forces a figure into light mode with black text so exports look the same
% everywhere. returns the figure handle so calls can be chained.

    if nargin < 1 || isempty(fig), fig = gcf; end

    black = [0 0 0];
    set(fig, 'Color', 'w', 'InvertHardcopy', 'off');

    ax = findall(fig, 'Type', 'axes');
    for k = 1:numel(ax)
        a = ax(k);
        set(a, 'Color', 'w', ...
               'XColor', black, 'YColor', black, 'ZColor', black, ...
               'GridColor', black, 'MinorGridColor', black, ...
               'GridAlpha', 0.15, 'MinorGridAlpha', 0.10);
        lbl = [a.Title, a.XLabel, a.YLabel, a.ZLabel];
        for j = 1:numel(lbl)
            if isgraphics(lbl(j)), set(lbl(j), 'Color', black); end
        end
        % hide the toolbar
        try
            a.Toolbar.Visible = 'off';
        catch
        end
    end

    % recolour legends, colorbars and free text
    lg = findall(fig, 'Type', 'legend');
    for k = 1:numel(lg)
        set(lg(k), 'TextColor', black, 'Color', 'w', 'EdgeColor', [0.6 0.6 0.6]);
    end

    cb = findall(fig, 'Type', 'colorbar');
    for k = 1:numel(cb)
        set(cb(k), 'Color', black);
        if isgraphics(cb(k).Label), set(cb(k).Label, 'Color', black); end
    end

    txt = findall(fig, 'Type', 'text');
    for k = 1:numel(txt)
        set(txt(k), 'Color', black);
    end
end
