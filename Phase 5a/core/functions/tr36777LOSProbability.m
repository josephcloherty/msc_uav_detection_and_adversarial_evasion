function p = tr36777LOSProbability(scenario, hUT, d2D)
% returns the LOS probability for a link at UE height hUT and ground distance
% d2D, using TR 36.777 Table B-1 aerially and TR 38.901 Table 7.4.2-1 below.

    scenario = upper(string(scenario));
    switch scenario
        case "RMA"
            if hUT <= 10
                % TR 38.901 RMa
                if d2D <= 10
                    p = 1;
                else
                    p = exp(-(d2D - 10) / 1000);
                end
            elseif hUT <= 40
                p1 = max(15021 * log10(hUT) - 16053, 1000);
                d1 = max(1350.8 * log10(hUT) - 1602, 18);
                p  = aerialBandLOS(d2D, d1, p1);
            else   % always LOS
                p = 1;
            end

        case "UMA"
            if hUT <= 22.5
                % TR 38.901 UMa
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
            else   % always LOS
                p = 1;
            end

        case "UMI"
            if hUT <= 22.5
                % TR 38.901 UMi
                if d2D <= 18
                    p = 1;
                else
                    p = 18/d2D + exp(-d2D/36)*(1 - 18/d2D);
                end
            else   % aerial band
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
% shared aerial-band form from TR 36.777 Table B-1.
    if d2D <= d1
        p = 1;
    else
        p = d1/d2D + exp(-d2D/p1) * (1 - d1/d2D);
    end
end
