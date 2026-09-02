classdef ref3GPP
% recomputes the 3GPP propagation expressions independently of the simulator, as
% the calculated side of the Phase 5 validation.

    properties (Constant)
        % propagation velocity, TR 38.901 clause 7.4.1
        C = 3.0e8
    end

    methods (Static)

        function PL = pathloss38901(scenario, isLOS, fcHz, hBS, hUT, d2D, opts)
        % returns the TR 38.901 Table 7.4.1-1 pathloss in dB.
            if nargin < 7, opts = struct(); end
            scenario = upper(string(scenario));
            fcGHz = fcHz / 1e9;
            d3D   = hypot(d2D, hUT - hBS);
            c     = ref3GPP.getOr(opts, 'c', ref3GPP.C);

            switch scenario
                case "UMA"
                    hE = ref3GPP.getOr(opts, 'hE', 1);
                    dBP = 4 * (hBS - hE) * (hUT - hE) * fcHz / c;
                    PL1 = 28.0 + 22*log10(d3D) + 20*log10(fcGHz);
                    PL2 = 28.0 + 40*log10(d3D) + 20*log10(fcGHz) ...
                          - 9*log10(dBP^2 + (hBS - hUT)^2);
                    if d2D <= dBP, plLOS = PL1; else, plLOS = PL2; end
                    if isLOS
                        PL = plLOS;
                    else
                        plNLOS = 13.54 + 39.08*log10(d3D) + 20*log10(fcGHz) ...
                                 - 0.6*(hUT - 1.5);
                        PL = max(plLOS, plNLOS);
                    end

                case "UMI"
                    hE = ref3GPP.getOr(opts, 'hE', 1);
                    dBP = 4 * (hBS - hE) * (hUT - hE) * fcHz / c;
                    PL1 = 32.4 + 21*log10(d3D) + 20*log10(fcGHz);
                    PL2 = 32.4 + 40*log10(d3D) + 20*log10(fcGHz) ...
                          - 9.5*log10(dBP^2 + (hBS - hUT)^2);
                    if d2D <= dBP, plLOS = PL1; else, plLOS = PL2; end
                    if isLOS
                        PL = plLOS;
                    else
                        plNLOS = 35.3*log10(d3D) + 22.4 + 21.3*log10(fcGHz) ...
                                 - 0.3*(hUT - 1.5);
                        PL = max(plLOS, plNLOS);
                    end

                case "RMA"
                    W = ref3GPP.getOr(opts, 'W', 20);
                    h = ref3GPP.getOr(opts, 'h', 5);
                    dBP = 2*pi * hBS * hUT * fcHz / c;
                    pl1 = @(d) 20*log10(40*pi*d*fcGHz/3) ...
                               + min(0.03*h^1.72, 10)*log10(d) ...
                               - min(0.044*h^1.72, 14.77) ...
                               + 0.002*log10(h)*d;
                    if d2D <= dBP
                        plLOS = pl1(d3D);
                    else
                        plLOS = pl1(dBP) + 40*log10(d3D/dBP);
                    end
                    if isLOS
                        PL = plLOS;
                    else
                        plNLOS = 161.04 - 7.1*log10(W) + 7.5*log10(h) ...
                                 - (24.37 - 3.7*(h/hBS)^2)*log10(hBS) ...
                                 + (43.42 - 3.1*log10(hBS))*(log10(d3D) - 3) ...
                                 + 20*log10(fcGHz) ...
                                 - (3.2*(log10(11.75*hUT))^2 - 4.97);
                        PL = max(plLOS, plNLOS);
                    end

                otherwise
                    error('ref3GPP:badScenario', ...
                        'Scenario must be UMa, RMa, or UMi.');
            end
        end

        function PL = pathloss36777(scenario, isLOS, fcGHz, hUT, d3D)
        % returns the TR 36.777 Table B-2 aerial pathloss in dB.
            scenario = upper(string(scenario));
            switch scenario
                case "RMA"
                    losPL = max(23.9 - 1.8*log10(hUT), 20)*log10(d3D) ...
                            + 20*log10(40*pi*fcGHz/3);
                    if isLOS
                        PL = losPL;
                    else
                        nlosPL = -12 + (35 - 5.3*log10(hUT))*log10(d3D) ...
                                 + 20*log10(40*pi*fcGHz/3);
                        PL = max(losPL, nlosPL);
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
                    fspl  = 20*log10(d3D) + 20*log10(fcGHz) + 32.45;
                    losPL = max(fspl, 30.9 + (22.25 - 0.5*log10(hUT))*log10(d3D) ...
                                      + 20*log10(fcGHz));
                    if isLOS
                        PL = losPL;
                    else
                        nlosPL = 32.4 + (43.2 - 7.6*log10(hUT))*log10(d3D) ...
                                 + 20*log10(fcGHz);
                        PL = max(losPL, nlosPL);
                    end

                otherwise
                    error('ref3GPP:badScenario', ...
                        'Scenario must be UMa, RMa, or UMi.');
            end
        end

        function p = losProbability(scenario, hUT, d2D)
        % returns the LOS probability from TR 36.777 Table B-1 or TR 38.901
        % Table 7.4.2-1.
            scenario = upper(string(scenario));
            band = @(d1, p1) ref3GPP.aerialBandLOS(d2D, d1, p1);
            switch scenario
                case "RMA"
                    if hUT <= 10
                        if d2D <= 10
                            p = 1;
                        else
                            p = exp(-(d2D - 10)/1000);
                        end
                    elseif hUT <= 40
                        p = band(max(1350.8*log10(hUT) - 1602, 18), ...
                                 max(15021*log10(hUT) - 16053, 1000));
                    else
                        p = 1;                      % always LOS
                    end

                case "UMA"
                    if hUT <= 22.5
                        if d2D <= 18
                            p = 1;
                        else
                            if hUT <= 13
                                Cc = 0;
                            else
                                Cc = ((min(hUT, 23) - 13)/10)^1.5;
                            end
                            p = (18/d2D + exp(-d2D/63)*(1 - 18/d2D)) * ...
                                (1 + Cc*(5/4)*(d2D/100)^3*exp(-d2D/150));
                        end
                    elseif hUT <= 100
                        p = band(max(460*log10(hUT) - 700, 18), ...
                                 4300*log10(hUT) - 3800);
                    else
                        p = 1;                      % always LOS
                    end

                case "UMI"
                    if hUT <= 22.5
                        if d2D <= 18
                            p = 1;
                        else
                            p = 18/d2D + exp(-d2D/36)*(1 - 18/d2D);
                        end
                    else
                        p = band(max(294.05*log10(hUT) - 432.94, 18), ...
                                 233.98*log10(hUT) - 0.95);
                    end

                otherwise
                    error('ref3GPP:badScenario', ...
                        'Scenario must be UMa, RMa, or UMi.');
            end
            p = min(max(p, 0), 1);
        end

        function sigma = shadowFadingStd(scenario, isLOS, hUT, zBoundary, opts)
        % returns the shadow-fading standard deviation, from TR 36.777 Table B-3
        % above the boundary and TR 38.901 Table 7.4.1-1 below it.
            if nargin < 5, opts = struct(); end
            scenario = upper(string(scenario));
            if hUT > zBoundary
                switch scenario
                    case "RMA"
                        if isLOS, sigma = 4.2*exp(-0.0046*hUT); else, sigma = 6; end
                    case "UMA"
                        if isLOS, sigma = 4.64*exp(-0.0066*hUT); else, sigma = 6; end
                    case "UMI"
                        if isLOS, sigma = max(5*exp(-0.01*hUT), 2); else, sigma = 8; end
                    otherwise
                        error('ref3GPP:badScenario', ...
                            'Scenario must be UMa, RMa, or UMi.');
                end
            else
                switch scenario
                    case "RMA"
                        if isLOS
                            sigma = ref3GPP.rmaLOSSigma(hUT, opts);
                        else
                            sigma = 8;
                        end
                    case "UMA"
                        if isLOS, sigma = 4; else, sigma = 6;    end
                    case "UMI"
                        if isLOS, sigma = 4; else, sigma = 7.82; end
                    otherwise
                        error('ref3GPP:badScenario', ...
                            'Scenario must be UMa, RMa, or UMi.');
                end
            end
        end

        function A = anchors()
        % returns the values computed by hand from the source documents.
            mk = @(what, kind, args, expected) struct('what', what, ...
                'kind', kind, 'args', {args}, 'expected', expected);
            A = [ ...
                mk('Table B-1 UMa-AV, hUT 50 m, d2D 500 m',  'pLOS', {"UMa", 50, 500},   0.888749)
                mk('Table B-1 RMa-AV, hUT 25 m, d2D 800 m',  'pLOS', {"RMa", 25, 800},   0.904100)
                mk('Table B-1 UMi-AV, hUT 100 m, d2D 300 m', 'pLOS', {"UMi", 100, 300},  0.771170)
                mk('Table B-1 RMa-AV 100 % LOS above 40 m',  'pLOS', {"RMa", 41, 5000},  1)
                mk('Table B-1 UMa-AV 100 % LOS above 100 m', 'pLOS', {"UMa", 101, 5000}, 1)
                mk('Table 7.4.2-1 UMa, hUT 1.5 m, d2D 200 m','pLOS', {"UMa", 1.5, 200},  0.128048)
                mk('Table 7.4.2-1 RMa, d2D 500 m',           'pLOS', {"RMa", 1.5, 500},  0.612626)
                mk('Table 7.4.2-1 UMi, d2D 100 m',           'pLOS', {"UMi", 1.5, 100},  0.230985)
                mk('Table B-2 UMa-AV LOS',   'PLav', {"UMa", true,  2.6, 100, 520},  96.0515)
                mk('Table B-2 UMa-AV NLOS',  'PLav', {"UMa", false, 2.6, 100, 520}, 110.1533)
                mk('Table B-2 RMa-AV LOS',   'PLav', {"RMa", true,  2.6, 50, 1000}, 103.2668)
                mk('Table B-2 RMa-AV NLOS',  'PLav', {"RMa", false, 2.6, 50, 1000}, 106.7276)
                mk('Table B-2 UMi-AV LOS',   'PLav', {"UMi", true,  2.6, 100, 200},  88.0964)
                mk('Table B-2 UMi-AV NLOS',  'PLav', {"UMi", false, 2.6, 100, 200}, 105.1283)
                mk('Table B-3 UMa-AV LOS, hUT 100 m', 'SF', {"UMa", true, 100, 22.5}, 2.398190)
                mk('Table B-3 RMa-AV LOS, hUT 50 m',  'SF', {"RMa", true, 50,  10},   3.337041)
                mk('Table B-3 UMi-AV LOS floor at 2 dB','SF',{"UMi", true, 300, 22.5}, 2)
                ];
        end
    end

    methods (Static, Access = private)
        function sigma = rmaLOSSigma(hUT, opts)
        % returns the RMa LOS shadow fading: 4 dB inside the breakpoint, 6 dB
        % beyond it.
            d2D = ref3GPP.getOr(opts, 'd2D', []);
            hBS = ref3GPP.getOr(opts, 'hBS', []);
            fc  = ref3GPP.getOr(opts, 'fcHz', []);
            if isempty(d2D) || isempty(hBS) || isempty(fc)
                warning('ref3GPP:rmaSigmaNoGeometry', ...
                    ['RMa LOS shadow fading is distance dependent ' ...
                     '(Table 7.4.1-1); without opts.d2D, opts.hBS and ' ...
                     'opts.fcHz the near-in 4 dB branch is returned.']);
                sigma = 4;
                return;
            end
            c = ref3GPP.getOr(opts, 'c', ref3GPP.C);
            dBP = 2*pi*hBS*hUT*fc/c;          % Table 7.4.1-1 Note 5
            if d2D < dBP, sigma = 4; else, sigma = 6; end
        end

        function p = aerialBandLOS(d2D, d1, p1)
        % returns the shared aerial-band form of TR 36.777 Table B-1.
            if d2D <= d1
                p = 1;
            else
                p = d1/d2D + exp(-d2D/p1)*(1 - d1/d2D);
            end
        end

        function v = getOr(s, f, dflt)
            if isstruct(s) && isfield(s, f) && ~isempty(s.(f))
                v = s.(f);
            else
                v = dflt;
            end
        end
    end
end
