-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on mixed-effects model nodes from R and Python.
--
-- Each model result carries a build-time `meta` sidecar with hierarchical
-- facts (task, formula with random effects, grouping counts, fit metrics).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().
--
-- No Julia node: MixedModels.jl cannot precompile in the pinned Nix
-- environment, so Julia mixed models stay on the generic probe path.

p = pipeline {
    -- R linear mixed model (sleepstudy, 180 obs, 18 subjects)
    r_lmer = node(
        command = <{
            library(lme4)
            lmer(Reaction ~ Days + (Days | Subject), sleepstudy)
        }>,
        runtime = R
    )

    -- statsmodels mixed linear model (30 obs, 6 groups)
    py_mixed = node(
        command = <{
            import numpy as np
            import pandas as pd
            import statsmodels.api as sm
            df_mixed = pd.DataFrame({
                "y": [0.5, -0.2, 0.8, -1.1, 0.3, 0.9, -0.4, 0.1, 1.2, -0.7,
                      0.6, -0.3, 0.4, -0.9, 1.0, -0.1, 0.2, -0.5, 0.7, -1.2,
                      0.8, -0.6, 0.0, 0.5, -0.8, 1.1, -0.2, 0.9, -0.4, 0.3],
                "x": [0.1, -0.5, 0.9, -0.2, 0.4, -0.8, 0.6, -0.1, 0.3, -0.7,
                      0.5, -0.4, 0.8, -0.6, 0.2, -0.9, 0.7, -0.3, 0.0, 0.6,
                      -0.5, 0.4, -0.7, 0.1, 0.9, -0.2, 0.5, -0.8, 0.3, -0.1],
                "g": ["s0", "s1", "s2", "s3", "s4", "s5", "s0", "s1", "s2", "s3",
                      "s4", "s5", "s0", "s1", "s2", "s3", "s4", "s5", "s0", "s1",
                      "s2", "s3", "s4", "s5", "s0", "s1", "s2", "s3", "s4", "s5"]
            })
            sm.MixedLM.from_formula("y ~ x", df_mixed, groups = df_mixed["g"]).fit(reml = False)
        }>,
        runtime = Python
    )
}

print("===============================================")
print("explain().foreign_meta Mixed Facts Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta mixed facts.")
