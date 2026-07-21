scenario_type = 'uMA'; UE = [3.64,128.938,50]; LOS_state = 'LOS';

% This checks TR 36.777 Table B-3 (shadow fading standard deviation, aerial
% overlay only). Shadow fading is a statistical parameter, not a per-link
% deterministic value, so the "result to extract from the simulation" here
% is the empirical std() of many logged shadow-fading draws from the sim at
% this height/condition, compared against sigma_SF printed below -- not a
% single-sample comparison.
%
% As with the pathloss script, heights below the aerial threshold are the
% standard TR 38.901 terrestrial values and are not re-derived here:
%   UMa terrestrial:  LOS sigma = 4,    NLOS sigma = 6
%   UMi terrestrial:  LOS sigma = 4,    NLOS sigma = 7.82
%   RMa terrestrial:  LOS sigma = 4,    NLOS sigma = 8
% (all fixed dB constants, independent of distance/height, per Table 7.4.1-1
% of [4]; cross-check these against nrPathLoss directly rather than this script.)

if scenario_type == 'uMA'

    if UE(3) <= 22.5
        fprintf('uMA - UE height %.4f is below the aerial threshold (22.5m).\n', UE(3));
        fprintf('Terrestrial UMa: sigma_SF = 4 (LOS) / 6 (NLOS).\n');
        sigma_SF = NaN;
    else
        fprintf('uMA - Aerial UE - Height = %.4f, condition = %s\n', UE(3), LOS_state);
        if strcmp(LOS_state, 'LOS')
            % applicability 22.5m < hUT <= 300m
            sigma_SF = 4.64 * exp(-0.0006*UE(3));
        elseif strcmp(LOS_state, 'NLOS')
            % applicability 22.5m < hUT <= 100m (NLOS cannot occur above this,
            % since pLOS = 1 there)
            sigma_SF = 6;
        end
    end

elseif scenario_type == 'rMA'

    if UE(3) <= 10
        fprintf('rMA - UE height %.4f is below the aerial threshold (10m).\n', UE(3));
        fprintf('Terrestrial RMa: sigma_SF = 4 (LOS) / 8 (NLOS).\n');
        sigma_SF = NaN;
    else
        fprintf('rMA - Aerial UE - Height = %.4f, condition = %s\n', UE(3), LOS_state);
        if strcmp(LOS_state, 'LOS')
            % applicability 10m < hUT <= 300m
            sigma_SF = 4.2 * exp(-0.0046*UE(3));
        elseif strcmp(LOS_state, 'NLOS')
            % NLOS can only physically occur below the 40m upper
            % LOS-probability threshold
            sigma_SF = 6;
        end
    end

elseif scenario_type == 'uMI'

    if UE(3) <= 22.5
        fprintf('uMI - UE height %.4f is below the aerial threshold (22.5m).\n', UE(3));
        fprintf('Terrestrial UMi: sigma_SF = 4 (LOS) / 7.82 (NLOS).\n');
        sigma_SF = NaN;
    else
        fprintf('uMI - Aerial UE - Height = %.4f, condition = %s\n', UE(3), LOS_state);
        % applicability 22.5m < hUT <= 300m for both LOS and NLOS
        if strcmp(LOS_state, 'LOS')
            sigma_SF = max(5*exp(-0.01*UE(3)), 2);
        elseif strcmp(LOS_state, 'NLOS')
            sigma_SF = 8;
        end
    end

end

fprintf('sigma_SF (dB) = %.4f\n', sigma_SF);