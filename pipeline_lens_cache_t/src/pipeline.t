-- Pipeline Lens Cache Demo
--
-- Verifies that in-memory cache operations are correctly scoped
-- by pipeline identity and that read_node works after lens set.

print("=== 1. Lens Set + read_node Contract ===")
p  = pipeline { a = 1; b = 2 }
p2 = set(p, node_lens("a"), 10)
print("read_node(p2.a):   ", read_node(p2.a))   -- Expected: 10

print("")
print("=== 2. Direct Access Returns VComputedNode ===")
print("p2.a type:         ", p2.a)               -- Expected: computed_node<T>

print("")
print("=== 3. Cross-Pipeline Cache Isolation ===")
p_a = pipeline { x = 1; y = 2 }
p_b = pipeline { x = 3; y = 4 }
p_a2 = set(p_a, node_lens("x"), 100)
print("read_node(p_a2.x): ", read_node(p_a2.x))  -- Expected: 100 (from lens set)
print("read_node(p_b.x):  ", read_node(p_b.x))   -- Expected: unbuilt error, NOT 100

print("")
print("=== 4. Add Missing Pipeline Node ===")
p3     = pipeline { a = 1 }
p4     = set(p3, node_lens("b"), 2)
result = get(p4, node_lens("b"))
print("get(p4, node_lens(\"b\")): ", result)        -- Expected: 2

print("")
print("=== 5. Get Non-Existent Node Returns NA ===")
result2 = get(p3, node_lens("b"))
print("get(p3, node_lens(\"b\")): ", result2)       -- Expected: NA

print("")
print("=== Demo Complete ===")
