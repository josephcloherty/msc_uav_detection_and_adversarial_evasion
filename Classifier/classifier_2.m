% 1. Load the Kaggle dataset
data = readtable('Iris.csv');
X = data{:, 2:5}; 
Y = data.Species;

% 2. Create a Train/Test Split (80% Train, 20% Test)
% cvpartition randomly divides the dataset
cv = cvpartition(size(X, 1), 'HoldOut', 0.2);

% Extract the training and testing data using the generated indices
XTrain = X(training(cv), :);
YTrain = Y(training(cv));

XTest = X(test(cv), :);
YTest = Y(test(cv));

% 3. Train the Random Forest on the TRAINING data
numTrees = 50;
rfModel = TreeBagger(numTrees, XTrain, YTrain, 'Method', 'classification');

% 4. Predict the species for the unseen TEST data
predictedLabels = predict(rfModel, XTest);

% 5. Evaluate Performance
% Convert both the actual labels and predictions to categorical arrays
% This makes comparison and plotting much easier in MATLAB
actualCat = categorical(YTest);
predictedCat = categorical(predictedLabels);

% Calculate overall accuracy
correctPredictions = sum(actualCat == predictedCat);
totalPredictions = numel(actualCat);
accuracy = (correctPredictions / totalPredictions) * 100;

fprintf('Overall Model Accuracy: %.2f%%\n', accuracy);

% 6. Visualize with a Confusion Matrix
figure;
confusionchart(actualCat, predictedCat, ...
    'Title', 'Random Forest Performance on Iris Dataset', ...
    'RowSummary', 'row-normalized', ...
    'ColumnSummary', 'column-normalized');