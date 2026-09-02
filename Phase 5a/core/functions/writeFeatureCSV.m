function outPath = writeFeatureCSV(T, cfg)
% writes the windowed feature table to a schema-locked CSV and returns the
% path. formatting is fixed so the same seed regenerates the file byte-for-byte.

    schema = phase5FeatureSchema();
    assert(isequal(T.Properties.VariableNames, schema), ...
        'writeFeatureCSV:schemaMismatch', ...
        'Input table columns do not match the locked Phase 5 schema.');

    if isfield(cfg, 'outputDir') && ~isempty(cfg.outputDir)
        outDir = cfg.outputDir;
    else
        outDir = fullfile(fileparts(mfilename('fullpath')), '..', 'data');
    end
    if ~exist(outDir, 'dir'), mkdir(outDir); end

    outPath = fullfile(outDir, sprintf('features_%s_seed%d.csv', ...
        string(cfg.scenario), cfg.seed));

    fid = fopen(outPath, 'w');   % binary mode
    assert(fid > 0, 'writeFeatureCSV:openFailed', ...
        'Could not open %s for writing.', outPath);
    cleaner = onCleanup(@() fclose(fid));

    fprintf(fid, '%s\n', strjoin(schema, ','));
    for r = 1:height(T)
        parts = cell(1, numel(schema));
        parts{1} = char(T.scenario(r));
        num = T{r, 2:end};
        for c = 1:numel(num)
            if isnan(num(c))
                parts{c+1} = 'NaN';
            elseif num(c) == round(num(c)) && abs(num(c)) < 1e12
                parts{c+1} = sprintf('%d', round(num(c)));
            else
                parts{c+1} = sprintf('%.6f', num(c));
            end
        end
        fprintf(fid, '%s\n', strjoin(parts, ','));
    end
end
