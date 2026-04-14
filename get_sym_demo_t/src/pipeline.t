-- get() and sym() Demo with Assertions

p = pipeline {
  -- Define some nodes
  my_var = 42
  var_name = "my_var"

  -- Use get() to lookup nodes or variables
  val1 = get("my_var")
  test_val1 = assert(val1 == 42)

  -- Use get() with sym()
  val2 = get(sym(var_name))
  test_val2 = assert(val2 == 42)

  -- Collection indexing with get()
  my_list = [10, 20, 30, 40]
  val3 = get(my_list, 2)
  test_val3 = assert(val3 == 30)

  node_a = 100
  node_b = 200
  
  -- A node that decides which node to access dynamically via node_lens
  dynamic_access = \(p_self: Pipeline) {
    target = "node_a"
    get(p_self, node_lens(target))
  }
  test_dynamic = assert(dynamic_access == 100)

  -- Testing sym() construction
  target_col = "mpg"
  s = sym(target_col)
  test_sym = assert(type(s) == "Symbol")

  -- Using get with a Dict and Lens
  my_dict = {
    a = 1,
    b = 2
  }
  l = col_lens("b")
  val4 = get(my_dict, l)
  test_val4 = assert(val4 == 2)
  
  -- Final verification node
  all_passed = assert(
    test_val1 && test_val2 && test_val3 && test_dynamic && test_sym && test_val4
  )
}

-- Execution and results presentation
print("--- get() and sym() Pipeline Results ---")
print("All assertions passed:", p$all_passed)
print("val1 (42):", p$val1)
print("val2 (42):", p$val2)
print("val3 (30):", p$val3)
print("dynamic_access (100):", p$dynamic_access)
print("sym value (Symbol mpg):", p$s)
print("val4 (2):", p$val4)
print("---------------------------------------")
