function outPath = phase5_MergeDataset(dataDir, outName)
% concatenates every per-run feature CSV in a folder into one dataset file,
% checking each carries the locked schema.

    if nargin < 1 || isempty(dataDir)
        dataDir = fullfile(fileparts(mfilename('fullpath')), 'data');
    end
    dataDir = char(dataDir);
    if nargin < 2 || isempty(outName)
        outName = 'dataset_phase5.csv';
    end
    addpath(fullfile(fileparts(mfilename('fullpath')), 'core', 'functions'));

    % non-recursive: the smoke check writes elsewhere and its rows are
    % not comparable with dataset rows.
    files = dir(fullfile(dataDir, 'features_*.csv'));
    assert(~isempty(files), 'phase5_MergeDataset:noInputs', ...
        'No features_*.csv found in %s.', dataDir);
    [~, order] = sort(string({files.name}));
    files = files(order);

    schema = phase5FeatureSchema();
    header = strjoin(schema, ',');

    outPath = fullfile(dataDir, outName);
    fid = fopen(outPath, 'w');   % binary mode
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
