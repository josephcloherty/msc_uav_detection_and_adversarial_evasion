% exportDiag  Convenience script: export diagnostics for the 'results'
% struct currently in the workspace (from a phase4_UMa/phase4_RMa run).
addpath(fullfile(fileparts(mfilename('fullpath')), 'functions'));
exportRunDiagnostics(results)
