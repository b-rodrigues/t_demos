import pandas as pd
import numpy as np
from sklearn.linear_model import LinearRegression
from skl2onnx import convert_sklearn
from skl2onnx.common.data_types import FloatTensorType
import sys

def main():
    if len(sys.argv) < 2:
        print("Usage: python train_model.py <output_path>")
        sys.exit(1)
        
    output_path = sys.argv[1]
    
    # Generate some simple synthetic data
    np.random.seed(42)
    X = np.random.rand(100, 2).astype(np.float32)
    y = X[:, 0] * 2 + X[:, 1] * 3 + np.random.randn(100).astype(np.float32) * 0.1
    
    # Train the model
    model = LinearRegression()
    model.fit(X, y)
    
    # Convert to ONNX
    initial_type = [('float_input', FloatTensorType([None, 2]))]
    onnx_model = convert_sklearn(model, initial_types=initial_type)
    
    # Save the model
    with open(output_path, "wb") as f:
        f.write(onnx_model.SerializeToString())
        
    print(f"Model saved to {output_path}")

if __name__ == "__main__":
    main()
