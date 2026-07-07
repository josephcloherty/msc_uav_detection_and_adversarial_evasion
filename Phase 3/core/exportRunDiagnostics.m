function outPath = exportRunDiagnostics(results, outDir)
%exportRunDiagnostics Plain-data export of a finished run for external review.
%
%   OUTPATH = exportRunDiagnostics(RESULTS) takes the results struct
%   returned by phase3_Pipeline and writes
%       <Phase 3>/data/diagnostics_<scenario>_seed<seed>.mat
%   containing ONLY plain arrays, chars, and structs (no toolbox objects,
%   saved with -v7), so the file can be opened by any external tool for
%   bug-hunting and sanity checks. Contents:
%
%     scenario, seed        run identity
%     cfg                   full scenario config (function handles and
%                           strings converted to char)
%     posLog                times (1xT), xyz (Nx3xT), nodeIDs, rate
%     losMatrix, sfMatrix   per-link LOS draws and shadow-fading terms
%     gnb / ue              per-node ID, name, initial position; UEs also
%                           carry the ground-truth label
%     perUE(k)              featureNames, featureLog (one row per scan),
%                           handoverLog [from to time], handoverTimes,
%                           scan settings (period, start), label,
%                           sinrLog [time, SINR_gNB1..N] (per-scan per-gNB
%                           averaged SINR), ulSINRraw (numCells x samples
%                           raw SRS SINR ring buffer) and gNBCount (SRS
%                           samples received per gNB)
%     link(j)               one entry per gNB-UE pair with everything the
%                           channel build used, recomputed from the INITIAL
%                           geometry exactly as createScenarioChannels did:
%                           gnbID, ueID, d2D, d3D, hBS, hUT, isLOS (the
%                           actual seeded draw), pLOS (Table B-1 / 7.4.2-1
%                           probability), aerialBand, zodOffsetDeg
%                           (eq B.1.1-1/-2, 0 in NLOS/terrestrial),
%                           pathloss_dB (the model pathloss at the initial
%                           geometry for the drawn LOS state),
%                           pathloss_LOS_dB / pathloss_NLOS_dB (both
%                           branches for comparison), shadowFading_dB,
%                           losAngles [AoD AoA ZoD ZoA] (downlink
%                           convention), channelSeed, fastFading (text:
%                           which profile/builder the link got), and the
%                           desired CDL parameters where applicable
%     featureCSV            path of the schema-locked CSV for this run
%
%   Usage after a run:
%       results = phase3_Pipeline(cfg);   % or run a scenario script
%       exportRunDiagnostics(results)
%
%   The optional OUTDIR overrides the default data folder.

    cfg = results.extras.cfg;
    fn = fieldnames(cfg);
    for i = 1:numel(fn)
        v = cfg.(fn{i});
        if isa(v, 'function_handle'), cfg.(fn{i}) = func2str(v); end
        if isstring(v),               cfg.(fn{i}) = char(v);     end
    end

    d = struct();
    d.scenario  = char(string(results.extras.cfg.scenario));
    d.seed      = results.extras.cfg.seed;
    d.cfg       = cfg;
    d.posLog    = results.posLog;
    d.losMatrix = double(results.linkInfo.los);
    d.sfMatrix  = results.linkInfo.sf;
    d.featureCSV = char(results.csvPath);

    d.gnb = struct('id', {}, 'name', {}, 'position', {});
    for i = 1:numel(results.gNBs)
        d.gnb(i) = struct('id', results.gNBs(i).ID, ...
            'name', char(results.gNBs(i).Name), ...
            'position', results.gNBs(i).Position);
    end

    d.ue = struct('id', {}, 'name', {}, 'position', {}, 'label', {});
    d.perUE = struct('ueID', {}, 'label', {}, 'featureNames', {}, ...
        'featureLog', {}, 'handoverLog', {}, 'handoverTimes', {}, ...
        'scanPeriod', {}, 'scanStartTime', {}, 'sinrLog', {}, ...
        'ulSINRraw', {}, 'gNBCount', {});
    for k = 1:numel(results.managers)
        m = results.managers{k};
        d.ue(k) = struct('id', m.UE.ID, 'name', char(m.UE.Name), ...
            'position', m.UE.Position, ...
            'label', double(m.ueLabel == "aerial"));
        if isprop(m, 'sinrLog'), sl = m.sinrLog; else, sl = []; end
        d.perUE(k) = struct( ...
            'ueID', m.UE.ID, ...
            'label', char(m.ueLabel), ...
            'featureNames', {m.featureNames}, ...
            'featureLog', m.featureLog, ...
            'handoverLog', m.handoverLog, ...
            'handoverTimes', m.handoverTimes(:), ...
            'scanPeriod', m.scanPeriod, ...
            'scanStartTime', m.scanStartTime, ...
            'sinrLog', sl, ...
            'ulSINRraw', m.ulSINR, ...
            'gNBCount', m.gNBCount(:));
    end

    % ---- Full per-link record, recomputed from the INITIAL geometry -----
    % (identical order and formulas to createScenarioChannels, so channel
    % seeds line up: linkIdx increments UE-fastest within each gNB)
    c0 = results.extras.cfg;                 % original (unsanitised) cfg
    fcGHz = c0.carrierFrequency / 1e9;
    plc = nrPathLossConfig;
    switch upper(string(c0.scenario))
        case "UMA", plc.Scenario = 'UMa'; plc.EnvironmentHeight = 1;
        case "RMA", plc.Scenario = 'RMa';
        case "UMI", plc.Scenario = 'UMi'; plc.EnvironmentHeight = 1;
    end
    d.link = struct('gnbID', {}, 'ueID', {}, 'd2D', {}, 'd3D', {}, ...
        'hBS', {}, 'hUT', {}, 'isLOS', {}, 'pLOS', {}, 'aerialBand', {}, ...
        'zodOffsetDeg', {}, 'pathloss_dB', {}, 'pathloss_LOS_dB', {}, ...
        'pathloss_NLOS_dB', {}, 'shadowFading_dB', {}, 'losAngles', {}, ...
        'channelSeed', {}, 'fastFading', {}, 'desiredK_dB', {}, ...
        'desiredDS_ns', {}, 'desiredAS_deg', {});
    linkIdx = 0;
    for i = 1:size(c0.gNBPositions, 1)
        gPos = c0.gNBPositions(i, :);
        gID = d.gnb(i).id;
        for u = 1:size(c0.uePositions, 1)
            linkIdx = linkIdx + 1;
            uPos = c0.uePositions(u, :);
            uID = d.ue(u).id;
            dxy = uPos(1:2) - gPos(1:2);
            d2D = max(norm(dxy), 1);
            d3D = max(norm(uPos - gPos), 1);
            hUT = uPos(3); hBS = gPos(3);
            isLOS = logical(d.losMatrix(gID, uID));
            pLOS = tr36777LOSProbability(c0.scenario, hUT, d2D);
            aerialBand = hUT > c0.zBoundary;

            % Pathloss at the initial geometry, both branches
            if aerialBand
                plL = tr36777AerialPathloss(c0.scenario, true,  fcGHz, hUT, d3D);
                plN = tr36777AerialPathloss(c0.scenario, false, fcGHz, hUT, d3D);
            else
                plL = nrPathLoss(plc, c0.carrierFrequency, 1, gPos', uPos');
                plN = nrPathLoss(plc, c0.carrierFrequency, 0, gPos', uPos');
            end
            if isLOS, plUsed = plL; else, plUsed = plN; end

            % ZOD offset per Annex B.1.1 Step 5 (LOS aerial band only)
            zodOff = 0;
            if aerialBand && isLOS
                switch upper(string(c0.scenario))
                    case "RMA"
                        zodOff = atand((hBS + hUT)/d2D) + atand((hUT - hBS)/d2D);
                    case "UMA"
                        zodOff = atand((hBS + hUT - 2*c0.avgBuildingHeight)/d2D) ...
                                 + atand((hUT - hBS)/d2D);
                end
            end

            % LOS geometric angles (downlink convention)
            aod = atan2d(dxy(2), dxy(1));
            aoa = mod(aod + 180 + 180, 360) - 180;
            zod = acosd((hUT - hBS)/d3D);
            zoa = acosd((hBS - hUT)/d3D);

            % Which fast-fading path the link received, plus CDL targets
            kDes = NaN; dsDes = NaN; asDes = [NaN NaN NaN NaN];
            if aerialBand && isfield(c0, 'aerialChannelBuilder') ...
                    && ~isempty(c0.aerialChannelBuilder)
                ff = 'UMi-AV reverse-UMa clause 7.5 (buildUMiAVChannel)';
            elseif aerialBand
                ff = 'TR 36.777 Alt-1 CDL-D custom (buildAerialCDL)';
                if isLOS, av = c0.av.los; else, av = c0.av.nlos; end
                kDes = av.K_dB; dsDes = av.DS_s * 1e9;
                asDes = [av.ASD av.ASA av.ZSD av.ZSA];
            elseif isLOS
                ff = 'built-in CDL-D, Table 7.5-6 median DS';
            else
                ff = 'built-in CDL-C, Table 7.5-6 median DS';
            end

            d.link(linkIdx) = struct('gnbID', gID, 'ueID', uID, ...
                'd2D', d2D, 'd3D', d3D, 'hBS', hBS, 'hUT', hUT, ...
                'isLOS', double(isLOS), 'pLOS', pLOS, ...
                'aerialBand', double(aerialBand), 'zodOffsetDeg', zodOff, ...
                'pathloss_dB', plUsed, 'pathloss_LOS_dB', plL, ...
                'pathloss_NLOS_dB', plN, ...
                'shadowFading_dB', d.sfMatrix(gID, uID), ...
                'losAngles', [aod aoa zod zoa], ...
                'channelSeed', c0.seed*1000 + linkIdx, ...
                'fastFading', ff, 'desiredK_dB', kDes, ...
                'desiredDS_ns', dsDes, 'desiredAS_deg', asDes);
        end
    end

    if nargin < 2 || isempty(outDir)
        outDir = fullfile(fileparts(mfilename('fullpath')), '..', 'data');
    end
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    outPath = fullfile(outDir, sprintf('diagnostics_%s_seed%d.mat', ...
        d.scenario, d.seed));
    save(outPath, '-struct', 'd', '-v7');
    fprintf('Diagnostics exported: %s\n', outPath);
end
