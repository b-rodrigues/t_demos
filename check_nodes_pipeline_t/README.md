# Check Nodes Pipeline Demo

This project demonstrates T's ability to orchestrate a polyglot pipeline involving T, R, Python, and Bash.

## Nodes:

1.  **`data_t` (T)**: A T node that generates a native list.
2.  **`df_r` (R)**: An R node that creates a DataFrame and outputs it using **Arrow**.
3.  **`df_py` (Python)**: A Python node that consumes the R Arrow output, transformations it, and outputs **Arrow**.
4.  **`model_r` (R)**: An R node that trains a model on the Python-processed data and outputs a summary as **JSON**.
5.  **`vector_py` (Python)**: A Python node that generates a linspace vector and outputs as **JSON**.
6.  **`res_bash` (Bash)**: A Bash node that summarizes all previous artifacts and outputs as **Text**.

## Features shown:

- Nix-managed sandboxes for R and Python (specified in `tproject.toml`).
- Cross-language serialization via **Arrow** and **JSON**.
- Dependency tracking across languages.
- Visualization in GitHub Actions using `read_node`.
