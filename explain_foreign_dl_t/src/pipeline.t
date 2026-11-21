-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on deep learning, transformers, catboost, and Julia Flux/MCMC/SciML/MultivariateStats nodes.

p = pipeline {
    -- Python torch Sequential (total params = 4*8+8 + 8*2+2 = 58, leaf layers = 3)
    py_torch_seq = node(
        command = <{
            import torch.nn as nn
            nn.Sequential(nn.Linear(4, 8), nn.ReLU(), nn.Linear(8, 2))
        }>,
        runtime = Python
    )

    -- Python nested torch nn.Module (2 direct children, 3 leaf layers)
    py_torch_nested = node(
        command = <{
            import torch.nn as nn
            nn.Sequential(
                nn.Sequential(nn.Linear(4, 8), nn.ReLU()),
                nn.Linear(8, 2)
            )
        }>,
        runtime = Python
    )

    -- Python plain int (verifies torch is not imported for unclassified objects)
    py_plain = node(
        command = <{
            42
        }>,
        runtime = Python
    )

    -- Python Keras Sequential with optimizer
    py_keras = node(
        command = <{
            import keras
            m = keras.Sequential([
                keras.Input(shape = (4,)),
                keras.layers.Dense(8, activation = "relu"),
                keras.layers.Dense(2)
            ])
            m.compile(optimizer = "adam", loss = "mse")
            m
        }>,
        runtime = Python
    )

    -- Python HuggingFace transformers model (offline config, no download)
    py_hf_model = node(
        command = <{
            from transformers import BertConfig, BertModel
            BertModel(BertConfig(
                hidden_size = 16,
                num_hidden_layers = 2,
                num_attention_heads = 2,
                intermediate_size = 32,
                vocab_size = 50
            ))
        }>,
        runtime = Python
    )

    -- Python CatBoost classifier
    py_catboost = node(
        command = <{
            from catboost import CatBoostClassifier
            CatBoostClassifier(iterations = 5, verbose = 0).fit(
                [[0, 0], [0, 1], [1, 0], [1, 1]],
                [0, 0, 1, 1]
            )
        }>,
        runtime = Python
    )

    -- Julia Flux Chain via selective import (no `using Flux`, tests Flux.trainables)
    jl_flux = node(
        command = <{
            import Flux: Chain, Dense, relu
            Chain(Dense(4 => 8, relu), Dense(8 => 2))
        }>,
        runtime = Julia
    )

    -- Julia MCMCChains.Chains
    jl_chains = node(
        command = <{
            using MCMCChains
            Chains(randn(40, 3, 2), [:a, :b, :c])
        }>,
        runtime = Julia
    )

    -- Julia SciMLBase ODEProblem
    jl_ode = node(
        command = <{
            using SciMLBase
            ODEProblem((u, p, t) -> -u, 1.0, (0.0, 2.5))
        }>,
        runtime = Julia
    )

    -- Julia MultivariateStats KernelPCA (0-1 var_first) & ICA
    jl_kpca = node(
        command = <{
            using MultivariateStats
            X = [1.0 2.0 3.0 4.0 5.0; 2.0 1.0 4.0 3.0 6.0]
            fit(KernelPCA, X; maxoutdim = 2)
        }>,
        runtime = Julia
    )

    jl_ica = node(
        command = <{
            using MultivariateStats
            X = [1.0 2.0 3.0 4.0 5.0 6.0; 2.0 1.5 4.0 3.5 6.0 5.5]
            fit(ICA, X, 2; maxiter = 50)
        }>,
        runtime = Julia
    )

    -- Julia GaussianMixtures GMM
    jl_gmm = node(
        command = <{
            using GaussianMixtures
            X = [1.0 1.1; 1.2 0.9; 5.0 5.1; 5.2 4.9; 1.0 1.0; 5.0 5.0]
            GMM(2, X)
        }>,
        runtime = Julia
    )

    -- Julia ARCHModels GARCH(1,1)
    jl_arch = node(
        command = <{
            using ARCHModels
            y = [0.1, -0.2, 0.3, -0.1, 0.2, -0.3, 0.4, -0.2, 0.1, -0.1,
                 0.2, -0.2, 0.3, -0.4, 0.1, -0.2, 0.3, -0.1, 0.2, -0.1]
            fit(GARCH{1, 1}, y)
        }>,
        runtime = Julia
    )

    -- Julia XGBoost Booster
    jl_xgb = node(
        command = <{
            using XGBoost
            X = [1.0 2.0; 2.0 3.0; 3.0 4.0; 4.0 5.0]
            y = [1.0, 2.0, 3.0, 4.0]
            xgboost((X, y); num_round = 3)
        }>,
        runtime = Julia
    )
}

print("===============================================")
print("explain().foreign_meta DL & Ecosystem Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta DL/ecosystem facts.")
