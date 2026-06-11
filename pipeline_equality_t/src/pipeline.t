-- Pipeline Equality Demo
--
-- Verifies == vs identical() semantics on VComputedNode.
-- == compares the node spec (structural equality); identical() compares
-- everything including pipeline identity. Lens-set nodes retain their
-- spec equality while gaining a different pipeline identity.
--
-- Uses build_pipeline to register targets so t_make() can resolve them
-- for CI inspection steps.

print("=== 1. Structural Equality: Same Value, Different Pipeline ===")
p1 = pipeline { a = 5; b = a * 2; c = b + 1 }
p2 = pipeline { a = 5; b = a * 2; c = b + 1 }
build_pipeline(p1, verbose=0)
build_pipeline(p2, verbose=0)

print("p1.c == p2.c:       ", p1.c == p2.c)        -- Expected: true
print("identical(p1.c, p2.c): ", identical(p1.c, p2.c))  -- Expected: false

print("")
print("=== 2. Cached Values Diverge After Lens Set ===")
p1b = set(p1, node_lens("a"), 99)
build_pipeline(p1b, verbose=0)
print("read_node(p1b.a):  ", read_node(p1b.a))  -- Expected: 99
print("p1b.a == p2.a:     ", p1b.a == p2.a)       -- Expected: true (same VComputedNode spec)
print("identical(p1b.a, p2.a): ", identical(p1b.a, p2.a))  -- Expected: false (different pipeline identity)

print("")
print("=== 3. Same Node Compared to Itself ===")
p   = pipeline { x = 42; y = x * 2 }
build_pipeline(p, verbose=0)
print("p.x == p.x:         ", p.x == p.x)           -- Expected: true
print("identical(p.x, p.x):   ", identical(p.x, p.x))  -- Expected: true

print("")
print("=== Demo Complete ===")

-- Assert correctness of == vs identical semantics
assert(p1.c == p2.c, "== should be true for equal specs")
assert(!identical(p1.c, p2.c), "identical() should be false for different pipelines")

assert(p.x == p.x, "== should be true for same node")
assert(identical(p.x, p.x), "identical() should be true for same node")

print("✓ pipeline_equality_t: all assertions passed")
