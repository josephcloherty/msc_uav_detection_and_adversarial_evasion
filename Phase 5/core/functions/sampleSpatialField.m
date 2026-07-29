function [u, z] = sampleSpatialField(F, k, x, y)
%sampleSpatialField Sample a correlated random field at a horizontal point.
%
%   [U, Z] = sampleSpatialField(F, K, X, Y) evaluates field K of the grid
%   built by buildSpatialField at the point (X, Y). Z is a standard normal
%   variate and U is the corresponding uniform variate on (0,1).
%
%   Interpolation and the unit-variance correction
%   ----------------------------------------------
%   Plain bilinear interpolation of independent standard normals does NOT
%   preserve the marginal distribution: the interpolated value has
%   variance sum(w.^2), which swings between 0.25 at a cell centre and 1
%   at a grid node. Left uncorrected, a LOS threshold test against this
%   field would be biased by where in the cell the UE happens to sit.
%
%   Dividing by sqrt(sum(w.^2)) restores exactly unit variance at every
%   point, so Z ~ N(0,1) and U ~ Uniform(0,1) EXACTLY, everywhere, while
%   the spatial correlation induced by sharing grid nodes is retained.
%   The resulting autocorrelation falls to zero at a lag of one grid cell
%   rather than following the exponential shape implied by TR 38.901; the
%   correlation DISTANCE is matched, the correlation SHAPE is not. This is
%   recorded in the deviations log.
%
%   U is produced with erfc rather than normcdf so that no Statistics and
%   Machine Learning Toolbox licence is required at run time:
%       Phi(z) = 0.5 * erfc(-z / sqrt(2))
%
%   See also buildSpatialField, linkState.

    fx = (x - F.x0) / F.h;
    fy = (y - F.y0) / F.h;

    % Clamp to the last full cell: a UE outside the padded grid is held at
    % the boundary value rather than erroring, so an unexpected excursion
    % degrades gracefully instead of killing a multi-hour run.
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
