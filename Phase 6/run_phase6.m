function run_phase6()
%RUN_PHASE6 Run the whole Phase 6 pipeline in order.
%   Each stage reads what the previous one wrote, so they must run in sequence. Running
%   this from scratch reproduces every number in the Phase 6 section of Chapter 4.
%
%   Stage                Deliverable  Writes
%   prepare_data         -            prepared_data/phase6_data.mat, leakage_check.csv
%   run_cv               D6.2         prepared_data/oof_scores.mat, results/cv_results*.csv
%   per_ue_rule          D6.3         prepared_data/ue_rule.mat, results/ue_rule_*.csv
%   thresholds           D6.4         prepared_data/thresholds.mat, results/thresholds.csv
%   latency_curve        D6.5         results/latency_curve.csv and .png
%   feature_importance   D6.6         results/feature_importance.csv and .png
%   freeze_models        D6.7         models/frozen_*.mat, results/freeze_manifest.csv
%
%   Exit: five frozen pipelines, each producing a window score, a per-UE score and a
%   decision at a threshold fixed without reference to any hold-out data. Apply one with
%   score_pipeline.m; nothing in Phase 7 should refit any part of them.
%
%   Each stage begins with clear, which would wipe this loop's own variables if the
%   stages were called from a script. They are called from a local function instead, so
%   each stage clears that function's workspace and leaves the loop intact.

root = fileparts(mfilename('fullpath'));
addpath(root);

stages = {'prepare_data', 'run_cv', 'per_ue_rule', 'thresholds', ...
          'latency_curve', 'feature_importance', 'freeze_models'};

t0 = tic;
for k = 1:numel(stages)
    fprintf('\n========================================================\n');
    fprintf(' Stage %d of %d: %s\n', k, numel(stages), stages{k});
    fprintf('========================================================\n');
    runStage(fullfile(root, [stages{k} '.m']));
end

fprintf('\nPhase 6 complete in %.1f minutes.\n', toc(t0) / 60);
end


%% ---- run one stage in its own workspace ----
function runStage(scriptPath)
    run(scriptPath);
end
