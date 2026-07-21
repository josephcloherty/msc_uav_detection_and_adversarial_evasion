% replayStart  Load and replay a saved Phase 4 run.
% Point this at a replay .mat saved from a phase4_UMa / phase4_RMa run,
% or call replayScenario directly with a results struct:
%   replayScenario(results.posLog, results.gNBs, results.UEs, ...
%                  results.managers, [], results.extras)
addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'core', 'functions'));
replayScenario('../data/replay_UMa_seed42');   % edit to your saved replay
