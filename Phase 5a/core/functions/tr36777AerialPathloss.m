function PL = tr36777AerialPathloss(scenario, isLOS, fcGHz, hUT, d3D)
% returns the aerial-band pathloss in dB for UMa, RMa or UMi per TR 36.777
% Table B-2. only valid above the aerial height floor; below it use nrPathLoss.

    scenario = upper(string(scenario));
    switch scenario
        case "RMA"
            losPL = max(23.9 - 1.8*log10(hUT), 20) * log10(d3D) ...
                    + 20*log10(40*pi*fcGHz/3);
            if isLOS
                PL = losPL;
            else
                PL = max(losPL, -12 + (35 - 5.3*log10(hUT))*log10(d3D) ...
                                 + 20*log10(40*pi*fcGHz/3));
            end

        case "UMA"
            if isLOS
                PL = 28.0 + 22*log10(d3D) + 20*log10(fcGHz);
            else
                PL = -17.5 + (46 - 7*log10(hUT))*log10(d3D) ...
                     + 20*log10(40*pi*fcGHz/3);
            end

        case "UMI"
            % PL' is free space
            fsplDB = 20*log10(d3D) + 20*log10(fcGHz) + 32.45;
            losPL  = max(fsplDB, 30.9 + (22.25 - 0.5*log10(hUT))*log10(d3D) ...
                                 + 20*log10(fcGHz));
            if isLOS
                PL = losPL;
            else
                PL = max(losPL, 32.4 + (43.2 - 7.6*log10(hUT))*log10(d3D) ...
                                 + 20*log10(fcGHz));
            end

        otherwise
            error('tr36777AerialPathloss:badScenario', ...
                'Scenario must be UMa, RMa, or UMi.');
    end
end
