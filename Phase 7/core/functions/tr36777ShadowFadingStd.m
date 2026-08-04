function sigma = tr36777ShadowFadingStd(scenario, isLOS, hUT, zBoundary)
%tr36777ShadowFadingStd Shadow-fading std dev per TR 36.777 Table B-3.
%
%   SIGMA = tr36777ShadowFadingStd(SCENARIO, ISLOS, HUT, ZBOUNDARY)
%   returns the lognormal shadow-fading standard deviation in dB.
%
%   Aerial band (hUT above ZBOUNDARY), from TR 36.777 Table B-3:
%     RMa-AV LOS:  4.2 * exp(-0.0046 * hUT)      (10 < hUT <= 300)
%     RMa-AV NLOS: 6                              (10 < hUT <= 40)
%     UMa-AV LOS:  4.64 * exp(-0.0066 * hUT)     (22.5 < hUT <= 300)
%     UMa-AV NLOS: 6                              (22.5 < hUT <= 100)
%     UMi-AV LOS:  max(5 * exp(-0.01 * hUT), 2)  (22.5 < hUT <= 300)
%     UMi-AV NLOS: 8                              (22.5 < hUT <= 300)
%
%   Terrestrial band: Table B-3 defers to TR 38.901 Table 7.4.1-1; the
%   standard terrestrial values are used (UMa 4/6, RMa 4/8, UMi 4/7.82,
%   LOS/NLOS respectively).

    scenario = upper(string(scenario));
    if hUT > zBoundary
        switch scenario
            case "RMA"
                if isLOS, sigma = 4.2 * exp(-0.0046 * hUT);
                else,     sigma = 6;
                end
            case "UMA"
                if isLOS, sigma = 4.64 * exp(-0.0066 * hUT);
                else,     sigma = 6;
                end
            case "UMI"
                if isLOS, sigma = max(5 * exp(-0.01 * hUT), 2);
                else,     sigma = 8;
                end
            otherwise
                error('tr36777ShadowFadingStd:badScenario', ...
                    'Scenario must be UMa, RMa, or UMi.');
        end
    else
        switch scenario
            case "RMA"
                if isLOS, sigma = 4;    else, sigma = 8;    end
            case "UMA"
                if isLOS, sigma = 4;    else, sigma = 6;    end
            case "UMI"
                if isLOS, sigma = 4;    else, sigma = 7.82; end
            otherwise
                error('tr36777ShadowFadingStd:badScenario', ...
                    'Scenario must be UMa, RMa, or UMi.');
        end
    end
end
