import pm_demo_pkg
import pm_demo_pkg[hello = greet]

result = greet("world")
alias_result = hello("T")

assert(result == "Hello, world!")
assert(alias_result == "Hello, T!")

print(alias_result)
