import pandas as pd
from pathlib import Path

def read_many_csvs(dir_path):
    folder = Path(dir_path)
    csv_files = folder.glob("*.csv")
    return pd.concat([pd.read_csv(f, sep="|") for f in csv_files], ignore_index=True)
