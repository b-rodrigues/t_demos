-- Pipeline Lens Demo
--
-- Demonstrates that lens operations (set, get, node_lens) modify
-- pipeline structure as pure operations. After applying a lens via
-- set(p, node_lens("name"), value), get(p, node_lens("name")) returns
-- the node's ComputedNode metadata. Direct pipeline access (p.name)
-- also returns a VComputedNode reference to the node.

print("=== 1. Lens Set + get Returns ComputedNode ===")
p  = pipeline { a = 1; b = 2 }
p2 = set(p, node_lens("a"), 10)
r1 = get(p2, node_lens("a"))
assert(type(r1) == "ComputedNode", "get(p2, node_lens('a')) should return a ComputedNode")
print("get(p2, node_lens('a')): ", r1)  -- Expected: computed_node<T>

print("")
print("=== 2. Direct Access Returns VComputedNode ===")
print("p2.a type:         ", p2.a)               -- Expected: computed_node<T>
assert(type(p2.a) == "ComputedNode", "p2.a should be a VComputedNode")

print("")
print("=== 3. Add Missing Pipeline Node ===")
p3     = pipeline { a = 1 }
p4     = set(p3, node_lens("b"), 2)
r3 = get(p4, node_lens("b"))
print("get(p4, node_lens(\"b\")): ", r3)        -- Expected: computed_node<T>
assert(type(r3) == "ComputedNode", "get(p4, node_lens('b')) should return a ComputedNode")

print("")
print("=== 4. Get Non-Existent Node Returns NA ===")
r4 = get(p3, node_lens("b"))
print("get(p3, node_lens(\"b\")): ", r4)       -- Expected: NA
assert(is_na(r4), "get(p3, node_lens('b')) should return NA for non-existent node")

print("")
print("=== Demo Complete ===")
