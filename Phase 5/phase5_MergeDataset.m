function outPath = phase5_MergeDataset(dataDir, outName)
%phase5_MergeDataset Concatenate the per-run feature CSVs into one dataset.
%
%   OUTPATH = phase5_MergeDataset()
%   OUTPATH = phase5_MergeDataset(DATADIR)
%   OUTPATH = phase5_MergeDataset(DATADIR, OUTNAME)
%
%   Reads every features_*.csv in DATADIR (default <Phase 5>/data), checks
%   that each carries exactly the locked feature schema, and writes their
%   rows into one file. DATADIR defaults to the batch output folder and
%   OUTNAME to dataset_phase5.csv.
%
%   Files are processed in sorted filename order and their body lines are
%   copied verbatim, so the merged file is a byte-exact concatenation of
%   the inputs under one header. Re-running the merge over the same
%   inputs therefore produces the same output byte for byte, and a
%   dataset assembled from runs split across several machines is
%   identical to one assembled on a single machine.
%
%   Each row already carries its scenario and seed, so provenance
%   survives the merge and the manifest can be joined back on those two
%   columns.

    if nargin < 1 || isempty(dataDir)
        dataDir = fullfile(fileparts(mfilename('fullpath')), 'data');
    end
    dataDir = char(dataDir);
    if nargin < 2 || isempty(outName)
        outName = 'dataset_phase5.csv';
    end
    addpath(fullfile(fileparts(mfilename('fullpath')), 'core', 'functions'));

    % Non-recursive by design: the smoke check writes its short-window
    % CSVs to data/smoke, whose rows are not comparable with dataset rows
    % and must never be swept into the dataset.
    files = dir(fullfile(dataDir, 'features_*.csv'));
    assert(~isempty(files), 'phase5_MergeDataset:noInputs', ...
        'No features_*.csv found in %s.', dataDir);
    [~, order] = sort(string({files.name}));
    files = files(order);

    schema = phase5FeatureSchema();
    header = strjoin(schema, ',');

    outPath = fullfile(dataDir, outName);
    fid = fopen(outPath, 'w');   % binary mode: \n stays \n everywhere
    assert(fid > 0, 'phase5_MergeDataset:openFailed', ...
        'Could not open %s for writing.', outPath);
    cleaner = onCleanup(@() fclose(fid)); %#ok<NASGU>
    fprintf(fid, '%s\n', header);

    totalRows = 0;
    for k = 1:numel(files)
        p = fullfile(files(k).folder, files(k).name);
        txt = fileread(p);
        lines = splitlines(string(txt));
        if lines(end) == "", lines(end) = []; end
        assert(~isempty(lines), 'phase5_MergeDataset:emptyFile', ...
            '%s is empty.', files(k).name);
        assert(strcmp(char(lines(1)), header), ...
            'phase5_MergeDataset:schemaMismatch', ...
            ['%s does not carry the locked Phase 5 feature schema (%d ' ...
             'columns). Files written before 29 July 2026 carry the ' ...
             'Phase 4 schema, which is a proper prefix of this one but ' ...
             'not equal to it, and they also predate the dynamic LOS ' ...
             'state, so their channel behaviour differs. They must be ' ...
             'regenerated rather than merged: mixing them in would ' ...
             'corrupt the dataset.'], ...
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
