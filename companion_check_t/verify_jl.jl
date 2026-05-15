using tlang, DataFrames, CSV
println(pipeline_nodes())

# read_node in Julia returns the path by default if no deserializer
path = read_node("data_node", return_path=true)
df = CSV.read(path, DataFrame)
println(df)
if nrow(df) == 3
    println("Julia verification successful")
else
    error("Julia verification failed")
end
