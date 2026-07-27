-- Pipeline Lens Cache Demo
--
-- Demonstrates that lens operations (set, get, node_lens) correctly
-- modify in-memory pipeline state. After applying a lens via
-- set(p, node_lens("name"), value), get(p, node_lens("name")) reflects
-- the modified value. Direct pipeline access (p.name) returns a
-- VComputedNode reference to the node.

print("=== 1. Lens Set + get Roundtrip ===")
p  = pipeline { a = 1; b = 2 }
p2 = set(p, node_lens("a"), 10)
r1 = get(p2, node_lens("a"))
assert(r1 == 10, "get(p2, node_lens('a')) should return the lens-set value 10")
print("get(p2, node_lens('a')): ", r1)  -- Expected: 10

print("")
print("=== 2. Direct Access Returns VComputedNode ===")
print("p2.a type:         ", p2.a)               -- Expected: computed_node<T>
assert(type(p2.a) == "ComputedNode", "p2.a should be a VComputedNode")

print("")
print("=== 3. Add Missing Pipeline Node ===")
p3     = pipeline { a = 1 }
p4     = set(p3, node_lens("b"), 2)
r3 = get(p4, node_lens("b"))
print("get(p4, node_lens(\"b\")): ", r3)        -- Expected: 2
assert(r3 == 2, "get(p4, node_lens('b')) should return the added node value 2")

print("")
print("=== 4. Get Non-Existent Node Returns NA ===")
r4 = get(p3, node_lens("b"))
print("get(p3, node_lens(\"b\")): ", r4)       -- Expected: NA
assert(is_na(r4), "get(p3, node_lens('b')) should return NA for non-existent node")

print("")
print("=== Demo Complete ===")
