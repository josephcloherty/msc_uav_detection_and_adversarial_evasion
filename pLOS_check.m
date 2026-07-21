scenario_type = 'rMA';

gNB = [0,0,25];

UE = [3.64,128.938,1.5];

d2D = sqrt((UE(1) - gNB(1))^2 + (UE(2) - gNB(2))^2);

d3D = sqrt((UE(1) - gNB(1))^2 + (UE(2) - gNB(2))^2 + (UE(3) - gNB(3))^2);

if scenario_type == 'uMA'
    if UE(3) < 22.5 %Terrestrial
        fprintf('uMA    -   Terrestrial UE   -   Height = %.4f\n', UE(3));
        if UE(3) <= 13
            Cprime = 0;
        elseif UE(3) <= 22.5
            Cprime = ((UE(3) - 13) / 10)^1.5;
        end
        if d2D <= 18 
            pLOS = 1
        elseif d2D > 18
            pLOS = (18/d2D + exp(-d2D/63)*(1 - 18/d2D)) * (1 + Cprime * (5/4) * (d2D/100)^3 * exp(-d2D/150));
        end
        fprintf('Cprime      = %.4f\n', Cprime);
    end

    if UE(3) > 22.5 %Aerial
        fprintf('uMA    -   Aerial UE   -   Height = %.4f\n', UE(3));
        p1 = (4300*log10(UE(3)))-3800;
        d1 = max(460*log10(UE(3))-700, 18);
        if UE(3) > 22.5 && UE(3) <= 100
            if d2D <= d1
                pLOS = 1;
            elseif d2D > d1
                pLOS = (d1/d2D)+exp(-d2D/p1)*(1-(d1/d2D));
            end
        elseif UE(3) > 100
            pLOS = 1
        elseif UE(3) < 22.5 %Terrestrial
            if d2D <= 18 
                pLOS = 1
            elseif d2D > 18
                pLOS = (18/d2D + exp(-d2D/63)*(1 - 18/d2D)) * (1 + Cprime * (5/4) * (d2D/100)^3 * exp(-d2D/150));
            end
        end
        fprintf('p1      = %.4f\n', p1);
        fprintf('d1      = %.4f\n', d1);
    end

    fprintf('d2D = %.4f\n', d2D);
    fprintf('d3D = %.4f\n', d3D);
    fprintf('pLOS    = %.4f\n', pLOS);

elseif scenario_type == 'rMA'

    if UE(3) <= 10 %Terrestrial
        fprintf('rMA - Terrestrial UE - Height = %.4f\n', UE(3));
        if d2D <= 10
            pLOS = 1;
        elseif d2D > 10
            pLOS = exp(-(d2D - 10)/1000);
        end
    end
 
    if UE(3) > 10 %Aerial
        fprintf('rMA - Aerial UE - Height = %.4f\n', UE(3));
        p1 = max(15021*log10(UE(3)) - 16053, 1000);
        d1 = max(1350.8*log10(UE(3)) - 1602, 18);
        if UE(3) > 10 && UE(3) <= 40
            if d2D <= d1
                pLOS = 1;
            elseif d2D > d1
                pLOS = (d1/d2D) + exp(-d2D/p1)*(1 - (d1/d2D));
            end
        elseif UE(3) > 40
            pLOS = 1;
        end
        fprintf('p1 = %.4f\n', p1);
        fprintf('d1 = %.4f\n', d1);
    end
 
    fprintf('d2D = %.4f\n', d2D);
    fprintf('d3D = %.4f\n', d3D);
    fprintf('pLOS = %.4f\n', pLOS);


elseif scenario_type == 'uMI'
    if UE(3) <= 22.5 %Terrestrial
        fprintf('uMI - Terrestrial UE - Height = %.4f\n', UE(3));
        if d2D <= 18
            pLOS = 1;
        elseif d2D > 18
            pLOS = 18/d2D + exp(-d2D/36)*(1 - 18/d2D);
        end
    end
 
    if UE(3) > 22.5 %Aerial
        fprintf('uMI - Aerial UE - Height = %.4f\n', UE(3));
        p1 = 233.98*log10(UE(3)) - 0.95;
        d1 = max(294.05*log10(UE(3)) - 432.94, 18);
        if d2D <= d1
            pLOS = 1;
        elseif d2D > d1
            pLOS = (d1/d2D) + exp(-d2D/p1)*(1 - (d1/d2D));
        end
        fprintf('p1 = %.4f\n', p1);
        fprintf('d1 = %.4f\n', d1);
    end
 
    fprintf('d2D = %.4f\n', d2D);
    fprintf('d3D = %.4f\n', d3D);
    fprintf('pLOS = %.4f\n', pLOS); 
end