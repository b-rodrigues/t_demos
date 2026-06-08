-- Pipeline Rename Cache Demo
--
-- Verifies that in-memory cache entries follow renamed nodes.

print("=== 1. Cache Migration on Rename ===")
p  = pipeline { a = 1; b = 2 }
p2 = set(p, node_lens("a"), 42)
print("read_node(p2.a):       ", read_node(p2.a))   -- Expected: 42 (cached value)

-- Rename 'a' to 'a_v2'
p3 = rename_node(p2, "a", "a_v2")
print("read_node(p3.a_v2):    ", read_node(p3.a_v2)) -- Expected: 42 (cache migrated)

print("")
print("=== 2. Old Name After Rename ===")
-- Access the old name; it should error (node no longer exists)
old_name_result = read_node(p3.a) ?|> \(x) if (is_error(x)) { str_sprintf("Error accessing old name: %s", error_msg(x)) } else { x }
print("read_node(p3.a):       ", old_name_result)    -- Expected: Error message about missing node

print("")
print("=== 3. Lens Set After Rename ===")
p4 = set(p3, node_lens("a_v2"), 99)
print("read_node(p4.a_v2):    ", read_node(p4.a_v2)) -- Expected: 99 (latest set)
print("read_node(p3.a_v2):    ", read_node(p3.a_v2)) -- Expected: 99 (set() returns same pipeline for existing nodes)
