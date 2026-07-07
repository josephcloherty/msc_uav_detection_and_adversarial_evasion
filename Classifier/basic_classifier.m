% 1. Load the Kaggle dataset
data = readtable('Iris.csv');

% 2. Separate features (X) and target labels (Y)
% We skip column 1 (Id) and use columns 2 through 5 for features. Column 6 is the label.
X = data{:, 2:5}; 
Y = data.Species;

% 3. Train the Random Forest (TreeBagger)
% We will use 50 decision trees for this minimal build
numTrees = 50;
rfModel = TreeBagger(numTrees, X, Y, 'Method', 'classification');

% 4. Test the model with a prediction
% Let's grab a random sample from our dataset (e.g., row 150) to see if it predicts correctly
testSample = X(150, :);
actualLabel = Y(150);

% predict() outputs a cell array of character vectors for classification
predictedLabel = predict(rfModel, testSample);

% 5. Display the results
fprintf('Actual Species: %s\n', actualLabel{1});
fprintf('Predicted Species: %s\n', predictedLabel{1});