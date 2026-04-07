-- src/lens_demo.t
-- Demonstrates functional lenses in T: "Reach the previously unreachable"

-- 1. Deep Nesting: The Pyramid of Doom no more
world = [
    countries: [
        [name: "Japan", cities: [
            [name: "Tokyo", pop: 14.0],
            [name: "Osaka", pop: 2.7]
        ]],
        [name: "Switzerland", cities: [
            [name: "Zurich", pop: 0.4],
            [name: "Geneva", pop: 0.2]
        ]]
    ]
]

pop_l = compose(col_lens("countries"), col_lens("cities"), col_lens("pop"))
world_boosted = world |> over(pop_l, \(p) p .* 1.05)

print("Populations before/after (Tokyo):")
-- Accessing nested data with lenses too!
tokyo_l = compose(col_lens("countries"), idx_lens(0), col_lens("cities"), idx_lens(0), col_lens("pop"))
print(get(world, tokyo_l))
print(get(world_boosted, tokyo_l)) -- 14.7

-- Standard indexing with the same 'get' function (formerly core.get)
print("Standard Indexing (Country 0):")
print(get(world.countries, 0).name)

-- 2. Positional Targeting: idx_lens()
switzerland_l = compose(col_lens("countries"), idx_lens(1))
print("Focused Country (Switzerland):")
print(get(world, switzerland_l).name)

-- 3. Precision Cell Edits in DataFrames: row_lens()
df = dataframe([
    [id: "A1", status: "pending", value: 100],
    [id: "A2", status: "pending", value: 200]
])

print("Original DataFrame:")
print(df)

cell_l = compose(row_lens(0), col_lens("status"))
df2 = df |> set(cell_l, "verified")
print("Updated DataFrame (row 0 marked verified):")
print(df2.status)

-- 4. Predicate Targeting: filter_lens()
-- Target and update only values where id contains "2"
id_2_l = compose(filter_lens(\(r) r.id == "A2"), col_lens("value"))
df3 = df2 |> over(id_2_l, \(v) v .* 5)
print("DataFrame after 5x boost for ID 'A2':")
print(df3.value)

-- 5. Orchestration: Injecting Pipeline Secrets
p = pipeline {
    data_node = 42
    secret_node = node(command = <{ Sys.getenv("API_KEY") }>, runtime = R)
}

key_l = env_var_lens("secret_node", "KEY_SCOPE")
p_injected = p |> set(key_l, "production")

print("Injected scope to pipeline node:")
print(get(p_injected, key_l))

print(" Lens Demo Complete ")
