-- Demo: end-to-end validation of explain(p.node).foreign_meta
-- on clustering and PCA nodes from R and Python.
--
-- Each result carries a build-time `meta` sidecar with cluster facts
-- (task, n_clusters, method, variance metrics).
-- Assertions run in a separate verify step (see the CI workflow), NOT here:
-- foreign_meta is only visible once build logs exist, i.e. after a real
-- build in a fresh process via t_make().

p = pipeline {
    -- R kmeans on mtcars (3 clusters, seeded)
    r_km = node(
        command = <{
            set.seed(1)
            kmeans(mtcars, 3)
        }>,
        runtime = R
    )

    -- R hierarchical clustering on mtcars
    r_hc = node(
        command = <{
            hclust(dist(mtcars))
        }>,
        runtime = R
    )

    -- scikit-learn KMeans (2 clusters)
    py_km = node(
        command = <{
            from sklearn.cluster import KMeans
            KMeans(n_clusters = 2, n_init = 10).fit([[1.0, 2.0], [2.0, 3.0], [3.0, 4.0], [8.0, 9.0]])
        }>,
        runtime = Python
    )

    -- scikit-learn PCA (2 components)
    py_pca = node(
        command = <{
            from sklearn.decomposition import PCA
            PCA(n_components = 2).fit([[1.0, 2.0], [2.0, 3.0], [3.0, 4.0], [8.0, 9.0]])
        }>,
        runtime = Python
    )

    -- Clustering.jl kmeans (2 clusters)
    jl_km = node(
        command = <{
            using Clustering
            kmeans([1.0 2.0 3.0 8.0; 2.0 3.0 4.0 9.0], 2)
        }>,
        runtime = Julia
    )

    -- Clustering.jl hierarchical clustering
    jl_hc = node(
        command = <{
            using Clustering
            hclust([0.0 1.0 2.0; 1.0 0.0 1.0; 2.0 1.0 0.0], linkage = :complete)
        }>,
        runtime = Julia
    )
}

print("===============================================")
print("explain().foreign_meta Cluster Facts Test")
print("===============================================")
print("")

res = build_pipeline(p, verbose = 1)

print("")
print("Pipeline build complete. Build log written to _pipeline/.")
print("Run the verify step to check foreign_meta cluster facts.")
