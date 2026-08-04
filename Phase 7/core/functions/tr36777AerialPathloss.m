function PL = tr36777AerialPathloss(scenario, isLOS, fcGHz, hUT, d3D)
%tr36777AerialPathloss Aerial-band pathloss per TR 36.777 Table B-2.
%
%   PL = tr36777AerialPathloss(SCENARIO, ISLOS, FCGHZ, HUT, D3D) returns
%   the pathloss in dB for an aerial-band link. SCENARIO is 'UMa', 'RMa',
%   or 'UMi'; ISLOS is the link's LOS state (logical); FCGHZ is the
%   carrier frequency in GHz; HUT the UE height in m; D3D the 3D distance
%   in m.
%
%   Covers the aerial band only, so below the floor the caller must use the
%   terrestrial TR 38.901 model instead.
%   Formulas from TR 36.777 Table B-2:
%
%     RMa-AV LOS:   max(23.9 - 1.8*log10(hUT), 20)*log10(d3D)
%                     + 20*log10(40*pi*fc/3)
%     RMa-AV NLOS:  max(PL_RMa-AV-LOS,
%                     -12 + (35 - 5.3*log10(hUT))*log10(d3D)
%                     + 20*log10(40*pi*fc/3))
%     UMa-AV LOS:   28.0 + 22*log10(d3D) + 20*log10(fc)
%                     (no breakpoint observed in the aerial band, Note 1)
%     UMa-AV NLOS:  -17.5 + (46 - 7*log10(hUT))*log10(d3D)
%                     + 20*log10(40*pi*fc/3)
%                     (stated validity 10 m < hUT <= 100 m, d2D <= 4 km;
%                      above 100 m the LOS probability is 100% so the
%                      NLOS branch is not expected to be exercised)
%     UMi-AV LOS:   max(FSPL(d3D, fc),
%                     30.9 + (22.25 - 0.5*log10(hUT))*log10(d3D)
%                     + 20*log10(fc))          (PL' is free-space, Note 3)
%     UMi-AV NLOS:  max(PL_UMi-AV-LOS,
%                     32.4 + (43.2 - 7.6*log10(hUT))*log10(d3D)
%                     + 20*log10(fc))

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
            % Note 3 of Table B-2: PL' is the free-space pathloss.
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
