function p = tr36777LOSProbability(scenario, hUT, d2D)
%tr36777LOSProbability LOS probability per TR 36.777 Table B-1 / TR 38.901 Table 7.4.2-1.
%
%   P = tr36777LOSProbability(SCENARIO, HUT, D2D) returns the line-of-sight
%   probability for a link with UE height HUT (m, above ground) and 2D
%   ground distance D2D (m). SCENARIO is 'UMa', 'RMa', or 'UMi'.
%
%   Below the aerial floor this uses the terrestrial TR 38.901 Table 7.4.2-1
%   formula, and inside the aerial band the TR 36.777 Table B-1 p1/d1 ones.
%   That includes the 100% LOS bands, RMa-AV above 40 m and UMa-AV above
%   100 m; UMi-AV keeps its formula all the way to 300 m.
%
%   Values, read from the source documents:
%     RMa-AV  (10 < hUT <= 40):  p1 = max(15021*log10(hUT) - 16053, 1000)
%                                d1 = max(1350.8*log10(hUT) - 1602, 18)
%     UMa-AV  (22.5 < hUT <= 100): p1 = 4300*log10(hUT) - 3800
%                                  d1 = max(460*log10(hUT) - 700, 18)
%     UMi-AV  (22.5 < hUT <= 300): p1 = 233.98*log10(hUT) - 0.95
%                                  d1 = max(294.05*log10(hUT) - 432.94, 18)
%   Aerial-band probability (all three): 1 for d2D <= d1, otherwise
%     d1/d2D + exp(-d2D/p1)*(1 - d1/d2D).

    scenario = upper(string(scenario));
    switch scenario
        case "RMA"
            if hUT <= 10
                % TR 38.901 Table 7.4.2-1, RMa
                if d2D <= 10
                    p = 1;
                else
                    p = exp(-(d2D - 10) / 1000);
                end
            elseif hUT <= 40
                p1 = max(15021 * log10(hUT) - 16053, 1000);
                d1 = max(1350.8 * log10(hUT) - 1602, 18);
                p  = aerialBandLOS(d2D, d1, p1);
            else   % 40 m < hUT <= 300 m: LOS probability is 100%
                p = 1;
            end

        case "UMA"
            if hUT <= 22.5
                % TR 38.901 Table 7.4.2-1, UMa (d2D-out taken as d2D:
                % all UEs in this scenario are outdoor)
                if d2D <= 18
                    p = 1;
                else
                    if hUT <= 13
                        C = 0;
                    else
                        C = ((min(hUT, 23) - 13) / 10)^1.5;
                    end
                    p = (18/d2D + exp(-d2D/63)*(1 - 18/d2D)) * ...
                        (1 + C * (5/4) * (d2D/100)^3 * exp(-d2D/150));
                end
            elseif hUT <= 100
                p1 = 4300 * log10(hUT) - 3800;
                d1 = max(460 * log10(hUT) - 700, 18);
                p  = aerialBandLOS(d2D, d1, p1);
            else   % 100 m < hUT <= 300 m: LOS probability is 100%
                p = 1;
            end

        case "UMI"
            if hUT <= 22.5
                % TR 38.901 Table 7.4.2-1, UMi - Street Canyon
                if d2D <= 18
                    p = 1;
                else
                    p = 18/d2D + exp(-d2D/36)*(1 - 18/d2D);
                end
            else   % 22.5 m < hUT <= 300 m (no 100% band for UMi-AV)
                p1 = 233.98 * log10(hUT) - 0.95;
                d1 = max(294.05 * log10(hUT) - 432.94, 18);
                p  = aerialBandLOS(d2D, d1, p1);
            end

        otherwise
            error('tr36777LOSProbability:badScenario', ...
                'Scenario must be UMa, RMa, or UMi.');
    end
    p = min(max(p, 0), 1);
end

function p = aerialBandLOS(d2D, d1, p1)
% Common aerial-band form from TR 36.777 Table B-1.
    if d2D <= d1
        p = 1;
    else
        p = d1/d2D + exp(-d2D/p1) * (1 - d1/d2D);
    end
end
