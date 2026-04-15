-- Pipeline Lens Orchestration Demo
-- 
-- Demonstrates how lenses can be used to surgically modify and 
-- inspect an existing pipeline specification at runtime.

-- 1. Define a standard multi-node pipeline
p = pipeline {
    data_gen = node(command = <{ [1, 2, 3, 4] }>)
    calc_a   = node(data_gen, command = <{ sum(data_gen) + 10 }>)
    calc_b   = node(data_gen, command = <{ sum(data_gen) * 2 }>)
    final    = node(calc_a, calc_b, command = <{ calc_a + calc_b }>)
}

print("--- Initial Pipeline ---")
print(p)

-- 2. Surgical Metadata Access: node_meta_lens
-- We can focus on the 'runtime' of calc_b and the 'noop' status of calc_a
a_noop_l = node_meta_lens("calc_a", "noop")
b_rt_l   = node_meta_lens("calc_b", "runtime")

print("\n--- Metadata Inspection ---")
print("calc_a noop status: ", get(p, a_noop_l))    -- False (default)
print("calc_b runtime:     ", get(p, b_rt_l))      -- "T"

-- 3. Surgical Edits: set() and over()
-- We want to toggle calc_a to noop and force calc_b to run in Python (simulated metadata change)
p2 = p |> 
     set(a_noop_l, true) |> 
     set(b_rt_l, "Python")

print("\n--- Modified Pipeline (p2) ---")
print("calc_a noop status: ", get(p2, a_noop_l))   -- True
print("calc_b runtime:     ", get(p2, b_rt_l))     -- "Python"

-- 4. Pipeline Traversals: filter_lens on VPipeline
-- We want to find all 'Python' nodes in the modified pipeline p2.
py_nodes_l = filter_lens(\(n) n.runtime == "Python")

-- get() on a filter_lens returns a List of matching data
py_node_values = get(p2, py_nodes_l)

print("\n--- Bulk Query via Traversal ---")
print("Values of all Python nodes: ", py_node_values)

-- 5. Bulk Transformation: over(filter_lens)
-- Suppose we want to globally tag every noop node with a custom serializer.
-- We traverse and focus on all noop nodes, then use a node-meta lens for surgical field updates.
-- Actually, we can compose filter_lens with other lenses!

noop_l = filter_lens(\(n) n.noop == true)
print("\n--- Noop Nodes ---")
print(get(p2, noop_l))

print("\n--- Demo Complete ---")
