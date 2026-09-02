function sigma = tr36777ShadowFadingStd(scenario, isLOS, hUT, zBoundary)
% returns the lognormal shadow-fading standard deviation in dB for the given
% scenario and LOS state, from TR 36.777 Table B-3 above zBoundary.

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
