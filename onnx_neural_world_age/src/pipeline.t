p = pipeline {
    processed_data = node(
        command = <{
import pandas as pd
import numpy as np
import os

# Create dummy data
df = pd.DataFrame({'x': np.random.rand(10).astype(np.float32), 'y': np.random.rand(10).astype(np.float32)})
processed_data = df.to_dict(orient='list')
        }>,
        runtime = Python,
        serializer = ^json
    )

    julia_flux_model = jln(
        processed_data,
        command = <{
            using Flux, JSON
            
            @info "Loading data from Python node..."
            df_dict = processed_data
            
            # Prepare data for Flux
            X = hcat(Float32.(df_dict["x"]), Float32.(df_dict["y"]))' |> collect
            # target is just a dummy for this demo
            y = fill(1.0f0, 1, size(X, 2))
            
            model = Chain(Dense(2, 1, sigmoid))
            
            data = [(X, y)]
            opt = Flux.setup(Flux.Adam(0.01f0), model)
            
            # High-level training
            # The T-lang emitter now wraps this in Base.invokelatest,
            # so this call should be safe from World Age errors.
            @info "Starting training (High-level Flux.train!)..."
            for epoch in 1:10
                Flux.train!(model, data, opt) do m, x, y_true
                    Flux.logitbinarycrossentropy(m(x), y_true)
                end
            end
            
            @info "Training complete."
            # Extract some state to return as the artifact
            julia_flux_model = Dict(
                "status" => "success",
                "final_loss" => Float64(Flux.logitbinarycrossentropy(model(X), y))
            )
        }>,
        deserializer = [processed_data: ^json],
        serializer = ^json
    )
}

print("==================================================")
print("T-LANG: FLUX WORLD AGE TEST")
print("==================================================")

res = populate_pipeline(p, build = true, verbose = 1)
if (is_error(res)) {
    print("\n[ERROR] Pipeline build failed:")
    print(error_message(res))
    exit(1)
}

print("\nJulia Flux Model results:")
print(read_node("julia_flux_model"))
