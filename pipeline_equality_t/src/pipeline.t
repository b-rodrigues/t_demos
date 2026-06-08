-- Pipeline Equality Demo
--
-- Verifies == vs identical() semantics on VComputedNode.
-- == compares value only; identical() compares everything.

print("=== 1. Structural Equality: Same Value, Different Pipeline ===")
p1 = pipeline { a = 5; b = a * 2; c = b + 1 }
p2 = pipeline { a = 5; b = a * 2; c = b + 1 }

print("p1.c == p2.c:       ", p1.c == p2.c)        -- Expected: true
print("identical(p1.c, p2.c): ", identical(p1.c, p2.c))  -- Expected: false

print("")
print("=== 2. Cached Values Diverge After Lens Set ===")
p1b = set(p1, node_lens("a"), 99)
print("read_node(p1b.a):  ", read_node(p1b.a))  -- Expected: 99
print("p1b.a == p2.a:     ", p1b.a == p2.a)       -- Expected: true (same VComputedNode spec)
print("identical(p1b.a, p2.a): ", identical(p1b.a, p2.a))  -- Expected: false (different pipeline identity)

print("")
print("=== 3. Same Node Compared to Itself ===")
p   = pipeline { x = 42; y = x * 2 }
print("p.x == p.x:         ", p.x == p.x)           -- Expected: true
print("identical(p.x, p.x):   ", identical(p.x, p.x))  -- Expected: true

print("")
print("=== Demo Complete ===")
