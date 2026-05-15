import tlang
print(tlang.pipeline_nodes())
import pandas as pd
import os

# read_node will return the path if we don't provide a deserializer or if it's unknown
# But let's try to pass pd.read_csv
df = tlang.read_node("data_node", deserializer=pd.read_csv)
print(df)
if len(df) == 3:
    print("Python verification successful")
else:
    raise ValueError("Python verification failed")
