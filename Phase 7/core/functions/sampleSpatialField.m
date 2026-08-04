function [u, z] = sampleSpatialField(F, k, x, y)
%sampleSpatialField Sample a correlated random field at a horizontal point.
%
%   [U, Z] = sampleSpatialField(F, K, X, Y) evaluates field K of the grid
%   from buildSpatialField at (X, Y), giving a standard normal Z and the
%   matching uniform U on (0,1).
%
%   Plain bilinear interpolation of independent normals does not preserve the
%   marginal: the value has variance sum(w.^2), which swings between 0.25 at
%   a cell centre and 1 at a node, so a LOS threshold test would be biased by
%   where in the cell the UE happens to sit.
%   Dividing by sqrt(sum(w.^2)) fixes that exactly while keeping the spatial
%   correlation that sharing grid nodes provides.
%
%   The autocorrelation then falls to zero at one grid cell rather than
%   decaying exponentially, so the correlation distance is matched but the
%   shape is not; see the deviations log.
%
%   U comes from erfc rather than normcdf so no Statistics toolbox licence is
%   needed at run time.
%
%   See also buildSpatialField, linkState.

    fx = (x - F.x0) / F.h;
    fy = (y - F.y0) / F.h;

    % Clamp to the last full cell, so a UE outside the padded grid gets the
    % boundary value rather than an error.
    i0 = min(max(floor(fx), 0), F.nx - 2);
    j0 = min(max(floor(fy), 0), F.ny - 2);
    tx = min(max(fx - i0, 0), 1);
    ty = min(max(fy - j0, 0), 1);

    w = [(1-tx)*(1-ty), tx*(1-ty), (1-tx)*ty, tx*ty];
    gv = [F.g(i0+1, j0+1, k), F.g(i0+2, j0+1, k), ...
          F.g(i0+1, j0+2, k), F.g(i0+2, j0+2, k)];

    z = sum(w .* gv) / sqrt(sum(w.^2));   % exactly unit variance
    u = 0.5 * erfc(-z / sqrt(2));         % exactly Uniform(0,1)
end
