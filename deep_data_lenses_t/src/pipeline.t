-- Demo: Surgical updates to nested data using functional lenses.

p = pipeline {
  -- 1. Create a deeply nested dictionary structure
  nested_data = node(command = [
    metadata: [
      owner: "antigravity",
      tags: ["data", "science", "reproducible"],
      config: [
        runtime: [
          lang: "T",
          version: "0.51.2"
        ],
        retry: 3
      ]
    ]
  ])

  -- 2. Use lenses to perform deep surgical updates
  -- We'll change the version number and append a new tag.
  updated_data = node(command = nested_data
    |> modify(
         compose("metadata", "config", "runtime", "version") |> set("0.51.3-rc"),
         compose("metadata", "tags") |> over(\(tags) tags |> append("validated")),
         compose("metadata", "config", "retry") |> over(\(x) x + 1)
       )
  )

  -- 3. Verify the change by pulling specific values
  final_check = node(command = updated_data
    |> view(compose("metadata", "config", "runtime", "version"))
  )
}

build_pipeline(p)
