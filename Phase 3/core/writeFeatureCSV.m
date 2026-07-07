function outPath = writeFeatureCSV(T, cfg)
%writeFeatureCSV Schema-locked, byte-reproducible CSV export (D3.1).
%
%   OUTPATH = writeFeatureCSV(T, CFG) writes the windowed feature table T
%   (from extractWindowedFeatures) to
%       <Phase 3>/data/features_<scenario>_seed<seed>.csv
%   and returns the full path. CFG fields used: cfg.scenario, cfg.seed,
%   and optionally cfg.outputDir (defaults to ../data relative to this
%   file, i.e. the Phase 3/data folder).
%
%   Reproducibility contract (exit criterion for D3.1): running the same
%   scenario script with the same seed must regenerate this file
%   byte-for-byte. writetable is NOT used because its float formatting is
%   version-dependent; instead every numeric value is printed with a fixed
%   %.6f format, NaN prints literally as NaN, and lines end with a bare
%   \n on every platform (file opened in binary 'w' mode so Windows does
%   not substitute \r\n).

    schema = phase3FeatureSchema();
    assert(isequal(T.Properties.VariableNames, schema), ...
        'writeFeatureCSV:schemaMismatch', ...
        'Input table columns do not match the locked Phase 3 schema.');

    if isfield(cfg, 'outputDir') && ~isempty(cfg.outputDir)
        outDir = cfg.outputDir;
    else
        outDir = fullfile(fileparts(mfilename('fullpath')), '..', 'data');
    end
    if ~exist(outDir, 'dir'), mkdir(outDir); end

    outPath = fullfile(outDir, sprintf('features_%s_seed%d.csv', ...
        string(cfg.scenario), cfg.seed));

    fid = fopen(outPath, 'w');   % binary mode: \n stays \n everywhere
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
