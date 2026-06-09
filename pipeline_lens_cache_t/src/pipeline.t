-- Pipeline Lens Cache Demo
--
-- Demonstrates that in-memory cache operations (set, read_node, get)
-- are correctly scoped by pipeline identity. After applying a lens via
-- set(p, node_lens("name"), value), read_node reflects the modified
-- value immediately. Cross-pipeline isolation is verified by ensuring
-- that modifying one pipeline's lens does not affect another pipeline,
-- and that read_node on an unbuilt pipeline returns an error.
--
-- Uses build_pipeline to register targets so t_make() can resolve them,
-- and assert(is_error(...)) to verify expected failure modes.

print("=== 1. Lens Set + read_node Contract ===")
p  = pipeline { a = 1; b = 2 }
p2 = set(p, node_lens("a"), 10)
build_pipeline(p, verbose=0)
build_pipeline(p2, verbose=0)
print("read_node(p2.a):   ", read_node(p2.a))   -- Expected: 10

print("")
print("=== 2. Direct Access Returns VComputedNode ===")
print("p2.a type:         ", p2.a)               -- Expected: computed_node<T>

print("")
print("=== 3. Cross-Pipeline Cache Isolation ===")
p_a = pipeline { x = 1; y = 2 }
p_b = pipeline { x = 3; y = 4 }
p_a2 = set(p_a, node_lens("x"), 100)
build_pipeline(p_a, verbose=0)
build_pipeline(p_a2, verbose=0)
print("read_node(p_a2.x): ", read_node(p_a2.x))  -- Expected: 100 (from lens set)
assert(is_error(read_node(p_b.x)), "p_b should be unbuilt — cross-pipeline cache isolation failed")
p_b_x = read_node(p_b.x) ?|> \(x) if (is_error(x)) { str_sprintf("Error (expected): %s", error_msg(x)) } else { x }
print("read_node(p_b.x):  ", p_b_x)

print("")
print("=== 4. Add Missing Pipeline Node ===")
p3     = pipeline { a = 1 }
p4     = set(p3, node_lens("b"), 2)
build_pipeline(p3, verbose=0)
build_pipeline(p4, verbose=0)
result = get(p4, node_lens("b"))
print("get(p4, node_lens(\"b\")): ", result)        -- Expected: 2

print("")
print("=== 5. Get Non-Existent Node Returns NA ===")
result2 = get(p3, node_lens("b"))
print("get(p3, node_lens(\"b\")): ", result2)       -- Expected: NA

print("")
print("=== Demo Complete ===")
