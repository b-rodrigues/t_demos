# Test Runner Features Demo (`test_runner_features_t`)

Demonstrates the `t test` runner: file discovery, `--only`/`--not` filtering, `--format json`/`junit` output, `.tignore` exclusion, the `t_test()` REPL function, and the `chain()`/`parallel()` fixture pipeline pattern.

## Project layout

```
tests/
├── .tignore              -- excludes slow and wip tests
├── test_arithmetic.t     -- passes
├── test_strings.t        -- passes
├── test_dataframe.t      -- passes (reads tests/data/sample.csv)
├── test_slow.t           -- excluded by .tignore
├── test_wip.t            -- excluded by .tignore (intentionally broken)
└── data/
    └── sample.csv
src/
└── pipeline.t            -- exercises t_test() and chain/parallel fixtures
```

## Features exercised

### Basic test discovery

`t test` discovers files matching `test-*.t`, `test_*.t`, or `*_test.t` in `tests/`:

```bash
t test
```

### Filtering with `--only` and `--not`

Run only tests whose path contains a substring:

```bash
t test --only arithmetic
t test --only test_arithmetic
```

Exclude tests whose path contains a substring:

```bash
t test --not slow
t test --not wip
```

Multiple filters combine (OR for `--only`, AND for `--not`):

```bash
t test --only arithmetic --only strings
t test --not slow --not wip
```

### Output formats

JSON output (machine-readable):

```bash
t test --format json
```

JUnit XML output (CI integration):

```bash
t test --format junit
```

Shorthand for JSON:

```bash
t test --json
```

### Coverage summary

Requires a coverage-instrumented build. From the tlang repo:

```bash
dune build --instrument-with bisect_ppx src/repl.exe
```

Then from the demo directory:

```bash
t test --coverage
```

This cleans old `.coverage` files, runs all tests, then prints a Bisect_ppx
coverage summary showing which T source files were exercised.

### `.tignore` exclusion

`tests/.tignore` lists patterns to exclude from discovery. Each line is a
case-insensitive substring matched against the test file's relative path.
Lines starting with `#` are comments.

```bash
# tests/.tignore
slow
wip
```

This excludes `test_slow.t` and `test_wip.t` from all `t test` runs without
renaming or deleting them. Useful for work-in-progress tests or expensive
tests you only run explicitly.

### `t_test()` REPL function

`t_test()` returns a DataFrame with columns `file`, `status`, `duration_ms`,
`error` — composable with testcraft assertions:

```bash
t run src/pipeline.t
```

### Fixture pipeline pattern (`chain()` + `parallel()`)

Use `chain()` to share a fixture pipeline's output across multiple test
pipelines. Each test pipeline references the fixture's node names as bare
variables — `chain()` resolves them by name:

```t
fixture = pipeline {
  data = node(
    command = read_csv("tests/data/sample.csv"),
    serializer = ^csv
  )
}

test_filter = pipeline {
  check_filter = node(
    command = {
      result = data |> filter($score >= 88)
      assert(expect_nrow(result, 2))
    },
    serializer = ^csv
  )
}

test_mutate = pipeline {
  check_mutate = node(
    command = {
      result = data |> mutate($pass = $score >= 70)
      assert(expect_in("pass", colnames(result)))
    },
    serializer = ^csv
  )
}

-- chain() wires fixture.data into both pipelines;
-- parallel() runs them independently (unique node names required)
combined = chain(fixture, parallel(test_filter, test_mutate))
build_pipeline(combined)
```

Each node runs in an isolated Nix sandbox. The fixture's `data` node builds a
dataframe, serializes it to CSV for cross-sandbox transfer, and downstream test
nodes receive it as a dataframe they can pipe directly.

## Running the demo

```bash
cd test_runner_features_t
t test                                  # human output
t test --format json                    # JSON
t test --format junit                   # JUnit XML
t test --only arithmetic                # filter
t test --not slow                       # exclude
t test --failfast                       # stop on first failure
t test --list                           # list tests without running
t test --timeout 10                     # mark slow tests as failed
t test --coverage                       # generate Bisect_ppx coverage summary
t run src/pipeline.t                    # t_test() + fixture pipeline
```
