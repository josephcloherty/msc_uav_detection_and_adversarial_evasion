function outPath = phase5b_MergeDataset(dataDir, outName)
%phase5b_MergeDataset Concatenate the per-run feature CSVs into one dataset.
%
%   OUTPATH = phase5b_MergeDataset()
%   OUTPATH = phase5b_MergeDataset(DATADIR)
%   OUTPATH = phase5b_MergeDataset(DATADIR, OUTNAME)
%
%   Reads every features_*.csv in DATADIR (default <Phase 7 copy>/data),
%   checks that each carries exactly the locked Phase 5b schema, and writes
%   their rows into one file. OUTNAME defaults to dataset_phase5b.csv.
%
%   Files are processed in sorted filename order and their body lines copied
%   verbatim, so the merge is byte-reproducible and a dataset assembled from
%   runs split across machines is identical to one assembled on one machine.
%
%   Each row carries its scenario and seed, so the manifest joins back on
%   those two columns.

    if nargin < 1 || isempty(dataDir)
        dataDir = fullfile(fileparts(mfilename('fullpath')), 'data');
    end
    dataDir = char(dataDir);
    if nargin < 2 || isempty(outName)
        outName = 'dataset_phase5b.csv';
    end
    addpath(fullfile(fileparts(mfilename('fullpath')), 'core', 'functions'));

    % Non-recursive by design: the smoke check writes short-window CSVs to
    % data/smoke, whose rows are not comparable and must not be swept in.
    files = dir(fullfile(dataDir, 'features_*.csv'));
    assert(~isempty(files), 'phase5b_MergeDataset:noInputs', ...
        'No features_*.csv found in %s.', dataDir);
    [~, order] = sort(string({files.name}));
    files = files(order);

    schema = phase5bFeatureSchema();
    header = strjoin(schema, ',');

    outPath = fullfile(dataDir, outName);
    fid = fopen(outPath, 'w');   % binary mode: \n stays \n everywhere
    assert(fid > 0, 'phase5b_MergeDataset:openFailed', ...
        'Could not open %s for writing.', outPath);
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid, '%s\n', header);

    totalRows = 0;
    for k = 1:numel(files)
        p = fullfile(files(k).folder, files(k).name);
        txt = fileread(p);
        lines = splitlines(string(txt));
        if lines(end) == "", lines(end) = []; end
        assert(~isempty(lines), 'phase5b_MergeDataset:emptyFile', ...
            '%s is empty.', files(k).name);
        assert(strcmp(char(lines(1)), header), ...
            'phase5b_MergeDataset:schemaMismatch', ...
            ['%s does not carry the locked Phase 5b feature schema (%d ' ...
             'columns). A Phase 5 file is a proper prefix of this one but ' ...
             'not equal to it and carries no RSRP, RSSI or RSRQ, so it ' ...
             'must be regenerated rather than merged.'], ...
            files(k).name, numel(schema));
        body = lines(2:end);
        for r = 1:numel(body)
            fprintf(fid, '%s\n', body(r));
        end
        totalRows = totalRows + numel(body);
    end

    fprintf('Merged %d file(s), %d row(s) x %d column(s) -> %s\n', ...
        numel(files), totalRows, numel(schema), outPath);
end
