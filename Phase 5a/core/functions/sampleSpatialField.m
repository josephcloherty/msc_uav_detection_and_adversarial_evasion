function [u, z] = sampleSpatialField(F, k, x, y)
% samples field k of a buildSpatialField grid at the point (x, y), returning a
% standard normal z and the matching uniform u.

    fx = (x - F.x0) / F.h;
    fy = (y - F.y0) / F.h;

    % clamp to the last full cell
    i0 = min(max(floor(fx), 0), F.nx - 2);
    j0 = min(max(floor(fy), 0), F.ny - 2);
    tx = min(max(fx - i0, 0), 1);
    ty = min(max(fy - j0, 0), 1);

    w = [(1-tx)*(1-ty), tx*(1-ty), (1-tx)*ty, tx*ty];
    gv = [F.g(i0+1, j0+1, k), F.g(i0+2, j0+1, k), ...
          F.g(i0+1, j0+2, k), F.g(i0+2, j0+2, k)];

    z = sum(w .* gv) / sqrt(sum(w.^2));   % unit variance
    u = 0.5 * erfc(-z / sqrt(2));         % uniform (0,1)
end
