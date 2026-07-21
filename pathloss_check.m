scenario_type = 'uMA'; gNB = [0,0,25]; UE = [3.64,128.938,50]; fc = 2.0; LOS_state = 'LOS';

% fc      : carrier frequency in GHz
% LOS_state : 'LOS' or 'NLOS' - the condition actually assigned to this link
%             by the simulation (from the Table B-1 pLOS draw), since the
%             aerial pathloss model is conditioned on which state applies.
%
% This script only implements the AERIAL overlay rows of TR 36.777 Table B-2
% (the custom part built on top of the toolbox). For UE(3) below the aerial
% threshold, cross-check against MATLAB's own nrPathLoss/nrPathLossConfig
% terrestrial models directly rather than re-deriving them here -- RMa's
% terrestrial formula in particular needs extra environment parameters
% (average building height, street width) that aren't part of this aerial
% overlay and are already handled natively by the toolbox.

d2D = sqrt((UE(1) - gNB(1))^2 + (UE(2) - gNB(2))^2);
d3D = sqrt((UE(1) - gNB(1))^2 + (UE(2) - gNB(2))^2 + (UE(3) - gNB(3))^2);

if scenario_type == 'uMA'

    if UE(3) <= 22.5
        fprintf('uMA - UE height %.4f is below the aerial threshold (22.5m).\n', UE(3));
        fprintf('Use nrPathLoss with a UMa terrestrial config to cross-check this link.\n');
        PL = NaN;
    else
        fprintf('uMA - Aerial UE - Height = %.4f, condition = %s\n', UE(3), LOS_state);
        % TR 36.777 Table B-2, applicability 22.5m < hUT <= 300m, d2D <= 4km
        PL_LOS = 28.0 + 22*log10(d3D) + 20*log10(fc);
        if strcmp(LOS_state, 'LOS')
            PL = PL_LOS;
        elseif strcmp(LOS_state, 'NLOS')
            % applicability 22.5m < hUT <= 100m (above 100m pLOS = 1, so NLOS
            % should not physically occur there)
            PL_NLOS_prime = -17.5 + (46 - 7*log10(UE(3)))*log10(d3D) + 20*log10(40*pi*fc/3);
            PL = max(PL_LOS, PL_NLOS_prime);
        end
    end

elseif scenario_type == 'rMA'

    if UE(3) <= 10
        fprintf('rMA - UE height %.4f is below the aerial threshold (10m).\n', UE(3));
        fprintf('Use nrPathLoss with an RMa terrestrial config to cross-check this link.\n');
        PL = NaN;
    else
        fprintf('rMA - Aerial UE - Height = %.4f, condition = %s\n', UE(3), LOS_state);
        % TR 36.777 Table B-2, applicability 10m < hUT (d2D <= 10km)
        PL_LOS = max(23.9 - 1.8*log10(UE(3)), 20) * log10(d3D) + 20*log10(fc);
        if strcmp(LOS_state, 'LOS')
            PL = PL_LOS;
        elseif strcmp(LOS_state, 'NLOS')
            % NLOS can only physically occur below the 40m upper LOS-probability
            % threshold (pLOS = 1 above that), even though the pathloss formula
            % itself is not explicitly range-limited in the table
            PL_NLOS_prime = -12 + (35 - 5.3*log10(UE(3)))*log10(d3D) + 20*log10(40*pi*fc/3);
            PL = max(PL_LOS, PL_NLOS_prime);
        end
    end

elseif scenario_type == 'uMI'

    if UE(3) <= 22.5
        fprintf('uMI - UE height %.4f is below the aerial threshold (22.5m).\n', UE(3));
        fprintf('Use nrPathLoss with a UMi terrestrial config to cross-check this link.\n');
        PL = NaN;
    else
        fprintf('uMI - Aerial UE - Height = %.4f, condition = %s\n', UE(3), LOS_state);
        % TR 36.777 Table B-2, applicability 22.5m < hUT <= 300m, d2D <= 4km
        % PL_free_space is the standard free-space pathloss (Note 3), used as
        % a floor so the aerial UMi model never predicts less loss than free space
        PL_free_space = 32.4 + 20*log10(fc) + 20*log10(d3D);
        PL_LOS = max(PL_free_space, 30.9 + (22.25 - 0.5*log10(UE(3)))*log10(d3D) + 20*log10(fc));
        if strcmp(LOS_state, 'LOS')
            PL = PL_LOS;
        elseif strcmp(LOS_state, 'NLOS')
            PL_NLOS_prime = 32.4 + (43.2 - 7.6*log10(UE(3)))*log10(d3D) + 20*log10(fc);
            PL = max(PL_LOS, PL_NLOS_prime);
        end
    end

end

fprintf('d2D = %.4f\n', d2D);
fprintf('d3D = %.4f\n', d3D);
fprintf('PL (dB) = %.4f\n', PL);