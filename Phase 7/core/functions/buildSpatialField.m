function F = buildSpatialField(seed, substream, numFields, extent, dcor)
%buildSpatialField Correlated random-variable grid (TR 38.901 clause 7.6.3.1).
%
%   F = buildSpatialField(SEED, SUBSTREAM, NUMFIELDS, EXTENT, DCOR) builds
%   NUMFIELDS independent spatially-correlated fields over the horizontal
%   plane, returned as a plain struct.
%
%   Option 2 of clause 7.6.3.1: independent normals on a grid spaced at the
%   correlation distance, interpolated from the four surrounding nodes.
%
%     SEED      - run seed, fixes the whole field
%     SUBSTREAM - substream index, separating this family from other
%                 consumers of the same seed
%     NUMFIELDS - one per gNB
%     EXTENT    - [xMin xMax yMin yMax] in metres, padded by two grid cells
%     DCOR      - correlation distance in metres, the grid spacing
%
%   The field is a pure function of its arguments and is never updated at run
%   time, so sampling is order-independent.
%
%   See also sampleSpatialField, linkState, createScenarioChannels.

    assert(numel(extent) == 4 && extent(2) >= extent(1) && extent(4) >= extent(3), ...
        'buildSpatialField:badExtent', ...
        'EXTENT must be [xMin xMax yMin yMax] with xMax >= xMin and yMax >= yMin.');
    assert(dcor > 0, 'buildSpatialField:badDcor', ...
        'Correlation distance must be positive.');
    assert(substream >= 1 && substream == round(substream), ...
        'buildSpatialField:badSubstream', ...
        'SUBSTREAM must be a positive integer.');

    h  = dcor;
    x0 = extent(1) - 2*h;   x1 = extent(2) + 2*h;
    y0 = extent(3) - 2*h;   y1 = extent(4) + 2*h;

    nx = max(ceil((x1 - x0)/h) + 1, 2);
    ny = max(ceil((y1 - y0)/h) + 1, 2);

    s = RandStream('Threefry', 'Seed', seed);
    s.Substream = substream;

    F = struct( ...
        'x0', x0, 'y0', y0, 'h', h, ...
        'nx', nx, 'ny', ny, 'n', numFields, ...
        'dcor', dcor, ...
        'g', randn(s, nx, ny, numFields));
end
