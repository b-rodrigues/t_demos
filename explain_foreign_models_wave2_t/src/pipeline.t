-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on wave-2 model nodes from R, Python, and Julia.
--
-- Each result carries a build-time `meta` sidecar with structured facts
-- (task, formula, method, metrics, n_obs, etc.).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R mgcv GAM with smooth terms
    r_gam = node(
        command = <{
            library(mgcv)
            gam(mpg ~ s(wt) + s(hp), data = mtcars)
        }>,
        runtime = R
    )

    -- R nlme linear mixed-effects model
    r_lme = node(
        command = <{
            library(nlme)
            lme(distance ~ age, Orthodont, random = ~ 1 | Subject)
        }>,
        runtime = R
    )

    -- R quantreg quantile regression
    r_rq = node(
        command = <{
            library(quantreg)
            rq(mpg ~ wt, data = mtcars, tau = 0.5)
        }>,
        runtime = R
    )

    -- R urca unit root test
    r_urca = node(
        command = <{
            library(urca)
            ur.df(AirPassengers, type = "drift")
        }>,
        runtime = R
    )

    -- R dist distance object
    r_dist = node(
        command = <{
            dist(mtcars[1:5, 1:4])
        }>,
        runtime = R
    )

    -- R sparse Matrix
    r_sparse = node(
        command = <{
            library(Matrix)
            sparseMatrix(i = c(1, 3), j = c(2, 4), x = c(5, 7), dims = c(4, 4))
        }>,
        runtime = R
    )

    -- Python Markov regime switching model
    py_markov = node(
        command = <{
            import numpy as np
            from statsmodels.tsa.regime_switching.markov_regression import MarkovRegression
            rng = np.random.default_rng(42)
            y = rng.normal(size = 40)
            MarkovRegression(y, k_regimes = 2).fit(disp = False)
        }>,
        runtime = Python
    )

    -- Julia CategoricalArray (factor kind)
    jl_factor = node(
        command = <{
            using CategoricalArrays
            categorical(["low", "med", "high", "med", "low"])
        }>,
        runtime = Julia
    )

    -- Julia MultivariateStats MulticlassLDA
    jl_mlda = node(
        command = <{
            using MultivariateStats
            X = [1.0 2.0 1.1 1.9 5.0 5.2 4.9 5.1; 0.9 1.1 2.0 1.8 3.0 3.2 2.9 3.1]
            y = [1, 1, 1, 1, 2, 2, 2, 2]
            fit(MulticlassLDA, X, y; outdim = 1)
        }>,
        runtime = Julia
    )

    -- R fitted tidymodels workflow ($fit$fit$spec)
    r_workflow = node(
        command = <{
            library(workflows)
            library(parsnip)
            wf <- workflow() |>
                add_model(rand_forest(trees = 10) |> set_engine("ranger") |> set_mode("classification")) |>
                add_formula(Species ~ Sepal.Length + Sepal.Width)
            fit(wf, data = iris)
        }>,
        runtime = R
    )

    -- R parsnip model_fit
    r_parsnip = node(
        command = <{
            library(parsnip)
            linear_reg() |> set_engine("lm") |> fit(mpg ~ wt + hp, data = mtcars)
        }>,
        runtime = R
    )

    -- R betareg (verifies scalar precision phi != 1 from logical TRUE)
    r_betareg = node(
        command = <{
            library(betareg)
            data("GasolineYield", package = "betareg")
            betareg(yield ~ batch + temp, data = GasolineYield)
        }>,
        runtime = R
    )

    -- R party::ctree (BinaryTree with n_nodes) & partykit::ctree
    r_binarytree = node(
        command = <{
            party::ctree(Species ~ ., data = iris)
        }>,
        runtime = R
    )

    r_partykit = node(
        command = <{
            partykit::ctree(Species ~ ., data = iris)
        }>,
        runtime = R
    )

    -- R caret::train regression (verifies metrics.r_squared)
    r_caret = node(
        command = <{
            set.seed(1)
            caret::train(mpg ~ wt + hp, data = mtcars, method = "lm",
                trControl = caret::trainControl(method = "cv", number = 3))
        }>,
        runtime = R
    )

    -- R kernlab::ksvm (verifies method includes kernel) & e1071::svm
    r_ksvm = node(
        command = <{
            kernlab::ksvm(Species ~ ., data = iris)
        }>,
        runtime = R
    )

    r_svm = node(
        command = <{
            e1071::svm(Species ~ ., data = iris)
        }>,
        runtime = R
    )

    -- R FactoMineR::PCA (verifies 0-1 var_first)
    r_factominer = node(
        command = <{
            FactoMineR::PCA(mtcars[, 1:4], graph = FALSE)
        }>,
        runtime = R
    )

    -- R ranger classification (verifies oob_error, n_trees) & glmnet
    r_ranger = node(
        command = <{
            ranger::ranger(Species ~ ., data = iris, num.trees = 50)
        }>,
        runtime = R
    )

    r_glmnet = node(
        command = <{
            set.seed(1)
            glmnet::cv.glmnet(as.matrix(mtcars[, -1]), mtcars$mpg)
        }>,
        runtime = R
    )

    -- R igraph, coda, dbscan, gbm, C5.0, earth, pls, Mclust, psych, lavaan, neuralnet
    r_igraph = node(
        command = <{
            igraph::make_ring(6)
        }>,
        runtime = R
    )

    r_coda = node(
        command = <{
            coda::mcmc(matrix(rnorm(100), ncol = 2))
        }>,
        runtime = R
    )

    r_dbscan = node(
        command = <{
            x <- matrix(c(0, 0.1, 0.2, 10, 10.1, 10.2, 50), ncol = 1)
            dbscan::dbscan(x, eps = 0.5, minPts = 2)
        }>,
        runtime = R
    )

    r_gbm = node(
        command = <{
            set.seed(1)
            gbm::gbm(mpg ~ wt + hp, data = mtcars, distribution = "gaussian", n.trees = 20)
        }>,
        runtime = R
    )

    r_c50 = node(
        command = <{
            C50::C5.0(Species ~ ., data = iris, trials = 3)
        }>,
        runtime = R
    )

    r_earth = node(
        command = <{
            earth::earth(mpg ~ wt + hp, data = mtcars)
        }>,
        runtime = R
    )

    r_mvr = node(
        command = <{
            pls::plsr(mpg ~ wt + hp + disp, data = mtcars, ncomp = 2)
        }>,
        runtime = R
    )

    r_mclust = node(
        command = <{
            mclust::Mclust(iris[, 1:4], G = 3, verbose = FALSE)
        }>,
        runtime = R
    )

    r_psych = node(
        command = <{
            psych::fa(mtcars[, 1:4], nfactors = 2, rotate = "varimax")
        }>,
        runtime = R
    )

    r_lavaan = node(
        command = <{
            lavaan::cfa("visual =~ x1 + x2 + x3", data = lavaan::HolzingerSwineford1939)
        }>,
        runtime = R
    )

    r_neuralnet = node(
        command = <{
            set.seed(1)
            neuralnet::neuralnet(mpg ~ wt + hp, data = mtcars, hidden = 2)
        }>,
        runtime = R
    )

    -- Python networkx, xarray, polars LazyFrame, PIL, gensim, dask, imblearn
    py_networkx = node(
        command = <{
            import networkx as nx
            nx.path_graph(5)
        }>,
        runtime = Python
    )

    py_xarray = node(
        command = <{
            import xarray as xr
            xr.Dataset({"temp": ("x", [1.0, 2.0, 3.0]), "salt": ("x", [30.0, 31.0, 32.0])})
        }>,
        runtime = Python
    )

    py_polars_lazy = node(
        command = <{
            import polars as pl
            pl.LazyFrame({"a": [1, 2], "b": [3, 4]})
        }>,
        runtime = Python
    )

    py_pil = node(
        command = <{
            from PIL import Image
            Image.new("RGB", (32, 16))
        }>,
        runtime = Python
    )

    py_gensim = node(
        command = <{
            from gensim.models import Word2Vec
            Word2Vec([["hello", "world", "tlang"], ["world", "tlang"]], vector_size = 8, min_count = 1)
        }>,
        runtime = Python
    )

    py_dask = node(
        command = <{
            import pandas as pd
            import dask.dataframe as dd
            dd.from_pandas(pd.DataFrame({"x": [1, 2, 3, 4], "y": [5, 6, 7, 8]}), npartitions = 2)
        }>,
        runtime = Python
    )

    py_imblearn = node(
        command = <{
            from imblearn.ensemble import BalancedRandomForestClassifier
            BalancedRandomForestClassifier(n_estimators = 5, random_state = 0).fit(
                [[0, 0], [0, 1], [1, 0], [1, 1], [1, 2], [2, 1]],
                [0, 0, 1, 1, 1, 1]
            )
        }>,
        runtime = Python
    )

    -- Julia import-only module qualification checks + Clustering.jl + Graphs.jl + JuMP
    jl_cat_import = node(
        command = <{
            import CategoricalArrays: categorical
            categorical(["x", "y", "x"])
        }>,
        runtime = Julia
    )

    jl_dist_import = node(
        command = <{
            import Distributions: Normal
            Normal(2.0, 3.0)
        }>,
        runtime = Julia
    )

    jl_cmeans = node(
        command = <{
            import Clustering: cmeans
            cmeans([1.0 2.0 8.0 9.0; 1.0 2.0 8.0 9.0], 2, 2.0)
        }>,
        runtime = Julia
    )

    jl_dbscan = node(
        command = <{
            import Clustering: dbscan
            dbscan([0.0 0.1 0.2 5.0 5.1 5.2 20.0; 0.0 0.0 0.0 0.0 0.0 0.0 0.0], 0.5, min_neighbors = 2)
        }>,
        runtime = Julia
    )

    jl_not_dbscan = node(
        command = <{
            (clusters = [1, 2, 3],)
        }>,
        runtime = Julia
    )

    jl_graphs_import = node(
        command = <{
            import Graphs: SimpleGraph, add_edge!
            g = SimpleGraph(4)
            add_edge!(g, 1, 2)
            add_edge!(g, 2, 3)
            g
        }>,
        runtime = Julia
    )

    jl_jump_import = node(
        command = <{
            import JuMP: Model, @variable, @constraint
            m = Model()
            @variable(m, x >= 0)
            @constraint(m, x <= 5)
            m
        }>,
        runtime = Julia
    )
}

print("===============================================")
print("explain().foreign_meta Wave 2 Models Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta wave 2 facts.")
