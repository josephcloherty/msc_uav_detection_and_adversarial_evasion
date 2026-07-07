numUEs = 11;
numgNBs = 7;

numLinks = numUEs * numgNBs;

constant = (1516 / 14);

est_sec = numLinks * constant;
est_min = est_sec / 60;
est_hrs = est_min / 60;

if est_sec < 60
    fprintf("%.4f Seconds", est_sec)
elseif est_sec > 60
    fprintf("%.4f Seconds   or  ", est_sec)
    fprintf("%.4f Minutes", est_min)
elseif est_sec > 3600
    fprintf("%.4f Seconds   or  ", est_sec)
    fprintf("%.4f Minutes   or  ", est_min)
    fprintf("%.4f Hours", est_hrs)
end
