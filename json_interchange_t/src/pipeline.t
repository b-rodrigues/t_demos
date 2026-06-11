-- Test JSON interchange between R and Python
-- Phase 1 of sandbox-interchange-protocol.md

config_node = node(
    command = <{
config_node <- list(alpha = 0.1, beta = 2)
    }>,
    runtime = R,
    serializer = ^json
)

process_node = node(
    command = <{
# config_node is read via the runtime JSON helper automatically
res = config_node["alpha"] + config_node["beta"]
process_node = {"result": res}
    }>,
    runtime = Python,
    deserializer = ^json,
    serializer = ^json
)

final_node = node(
    command = process_node.result * 2,
    deserializer = ^json
)

p = pipeline {
    config_node = config_node
    process_node = process_node
    final_node = final_node
}

print("Pipeline object:")
print(p)

print("Running build_pipeline(p, verbose=1)...")
p_store_path = build_pipeline(p, verbose=1)
print(str_join(["Pipeline built at: ", p_store_path], sep=""))

print("Verifying individual nodes via read_node:")
print("config_node data:")
c_data = read_node(p.config_node)
print(c_data)

print("process_node data:")
proc_data = read_node(p.process_node)
print(proc_data)

print("final_node data (T node):")
f_data = read_node(p.final_node)
print(f_data)

-- Node correctness assertions
assert(type(c_data.error) == "NA", "config_node (R JSON) should succeed")
assert(type(proc_data.error) == "NA", "process_node (Python JSON) should succeed")
assert(type(f_data.error) == "NA", "final_node (T JSON) should succeed")

-- Verify JSON interchange: config alpha=0.1 beta=2, process = 2.1, final = 4.2
assert(c_data.value.alpha == 0.1, "config should have alpha=0.1")
assert(c_data.value.beta == 2, "config should have beta=2")
assert(f_data.value == 4.2, "final should be (0.1+2)*2 = 4.2")

print("✓ json_interchange_t: all assertions passed")
