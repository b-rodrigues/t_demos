-- Pipeline Rename Cache Demo
--
-- Verifies that in-memory cache entries follow renamed nodes. After
-- rename_node(p, "old", "new"), the cached value is accessible under
-- the new name, and accessing the old name correctly errors.
--
-- Uses build_pipeline to register targets so t_make() can resolve them,
-- and assert(is_error(...)) to verify expected failure modes.

print("=== 1. Cache Migration on Rename ===")
p  = pipeline { a = 1; b = 2 }
p2 = set(p, node_lens("a"), 42)
build_pipeline(p, verbose=0)
build_pipeline(p2, verbose=0)
print("read_node(p2.a):       ", read_node(p2.a))   -- Expected: 42 (cached value)

-- Rename 'a' to 'a_v2'
p3 = rename_node(p2, "a", "a_v2")
build_pipeline(p3, verbose=0)
print("read_node(p3.a_v2):    ", read_node(p3.a_v2)) -- Expected: 42 (cache migrated)

print("")
print("=== 2. Old Name After Rename ===")
-- Access the old name; it should error (node no longer exists)
assert(is_error(read_node(p3.a)), "read_node(p3.a) should error: node was renamed")
old_name_result = read_node(p3.a) ?|> \(x) if (is_error(x)) { str_sprintf("Error accessing old name: %s", error_msg(x)) } else { x }
print("read_node(p3.a):       ", old_name_result)    -- Expected: Error message about missing node

print("")
print("=== 3. Lens Set After Rename ===")
p4 = set(p3, node_lens("a_v2"), 99)
build_pipeline(p4, verbose=0)
print("read_node(p4.a_v2):    ", read_node(p4.a_v2)) -- Expected: 99 (latest set)
print("read_node(p3.a_v2):    ", read_node(p3.a_v2)) -- Expected: 99 (set() returns same pipeline for existing nodes)
