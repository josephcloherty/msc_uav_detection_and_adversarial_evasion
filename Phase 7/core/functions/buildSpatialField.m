function F = buildSpatialField(seed, substream, numFields, extent, dcor)
%buildSpatialField Correlated random-variable grid (TR 38.901 clause 7.6.3.1).
%
%   F = buildSpatialField(SEED, SUBSTREAM, NUMFIELDS, EXTENT, DCOR) builds
%   NUMFIELDS independent spatially-correlated random fields over the
%   horizontal plane, returned as a plain struct so it can be stored in a
%   value-class property and passed to parallel workers without side
%   effects.
%
%   This is Option 2 of TR 38.901 clause 7.6.3.1 ("spatially consistent
%   random variables"): independent standard normal variables are drawn on
%   a regular grid whose spacing is the correlation distance DCOR from
%   Table 7.6.3.1-2, and the value at an arbitrary point is obtained by
%   interpolating the four surrounding grid nodes. Two points closer than
%   DCOR share grid nodes and are therefore correlated; two points further
%   apart than DCOR share none and are independent.
%
%   Inputs:
%     SEED      - run seed (cfg.seed); fixes the whole field
%     SUBSTREAM - substream index (>= 1) separating this field family from
%                 every other consumer of the same seed
%     NUMFIELDS - number of independent fields (one per gNB, so that two
%                 UEs at the same place see the same state for a given
%                 cell, which is the point of spatial consistency)
%     EXTENT    - [xMin xMax yMin yMax] in metres, the area the UEs can
%                 reach; padded by two grid cells so a UE that leaves the
%                 nominal bounds still lands inside the grid
%     DCOR      - correlation distance in metres (grid spacing)
%
%   Determinism: the field is a pure function of (SEED, SUBSTREAM,
%   NUMFIELDS, EXTENT, DCOR). It carries no state and is never updated at
%   run time, so sampling it is order-independent. This matters because
%   pathloss is evaluated per packet in whatever order the simulator
%   delivers them; a Markov-chain LOS state updated in place would make
%   the result depend on packet ordering and break the fixed-seed
%   byte-identical regeneration contract.
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
