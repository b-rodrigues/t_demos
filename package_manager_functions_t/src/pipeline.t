-- package_manager_functions_t
-- Exercise the package manager CLI and runtime package loading helpers.

demo_root = getwd()
package_workspace = path_join(demo_root, "outputs", "package_manager_package_workspace")
project_workspace = path_join(demo_root, "outputs", "package_manager_project_workspace")
package_root = path_join(package_workspace, "pm_demo_pkg")
project_root = path_join(project_workspace, "pm_demo_project")
consumer_script = path_join(demo_root, "src", "consumer_import.t")

p = pipeline {
  package_checks = {
    run(str_sprintf("sh -lc 'rm -rf \"%s\" && mkdir -p \"%s\"'", package_workspace, package_workspace))

    package_init_output = run(
      str_sprintf(
        "sh -lc 'cd \"%s\" && t init --package pm_demo_pkg --author \"Demo User <demo@example.com>\" --license MIT --context small'",
        package_workspace
      )
    )

    assert_file_exists(path_join(package_root, "DESCRIPTION.toml"))
    assert_file_exists(path_join(package_root, "src", "main.t"))
    assert_file_exists(path_join(package_root, "tests", "test-pm_demo_pkg.t"))
    assert_file_exists(path_join(package_root, "docs", "index.md"))

    run(str_sprintf("sh -lc 'cd \"%s\" && t run src/main.t'", package_root))
    run(str_sprintf("sh -lc 'cd \"%s\" && t test'", package_root))
    run(str_sprintf("sh -lc 'cd \"%s\" && t doc --parse --generate'", package_root))

    assert_file_exists(path_join(package_root, "docs", "reference", "index.md"))

    run(
      str_sprintf(
        "sh -lc 'cd \"%s\" && t doctor > doctor.txt && grep -q \"Detected T Package\" doctor.txt'",
        package_root
      )
    )

    run(
      str_sprintf(
        "sh -lc 'cd \"%s\" && T_BIN=$(command -v t) && SAVED_PATH=$PATH && PATH=\"\" \"$T_BIN\" docs > docs-open.txt 2>&1 && PATH=$SAVED_PATH grep -q \"Documentation location:\" docs-open.txt'",
        package_root
      )
    )

    run(str_sprintf("sh -lc 'cd \"%s\" && t update'", package_root))
    assert_file_exists(path_join(package_root, "flake.lock"))

    package_import_output = run(
      str_sprintf(
        "sh -lc 'cd \"%s\" && T_PACKAGE_PATH=\"%s\" t run \"%s\"'",
        package_workspace,
        package_workspace,
        consumer_script
      )
    )

    [
      init_output: package_init_output,
      docs_index: path_join(package_root, "docs", "reference", "index.md"),
      import_output: package_import_output,
      lockfile: path_join(package_root, "flake.lock")
    ]
  }

  project_checks = {
    run(str_sprintf("sh -lc 'rm -rf \"%s\" && mkdir -p \"%s\"'", project_workspace, project_workspace))

    project_init_output = run(
      str_sprintf(
        "sh -lc 'cd \"%s\" && t init --project pm_demo_project --author \"Demo User <demo@example.com>\" --license MIT --context small'",
        project_workspace
      )
    )

    assert_file_exists(path_join(project_root, "tproject.toml"))
    assert_file_exists(path_join(project_root, "src", "pipeline.t"))
    assert_dir_exists(path_join(project_root, "data"))
    assert_dir_exists(path_join(project_root, "outputs"))

    run(
      str_sprintf(
        "sh -lc 'cd \"%s\" && t run src/pipeline.t > project-run.txt && grep -q \"Hello from pm_demo_project pipeline!\" project-run.txt'",
        project_root
      )
    )

    run(
      str_sprintf(
        "sh -lc 'cd \"%s\" && t doctor > doctor.txt && grep -q \"Detected T Project\" doctor.txt'",
        project_root
      )
    )

    run(str_sprintf("sh -lc 'cd \"%s\" && t update'", project_root))
    assert_file_exists(path_join(project_root, "flake.lock"))

    [
      init_output: project_init_output,
      lockfile: path_join(project_root, "flake.lock"),
      pipeline_script: path_join(project_root, "src", "pipeline.t")
    ]
  }

}

build_pipeline(p, verbose = 1)

print("=== Package manager demo summary ===")
print([
  package_workspace: package_workspace,
  project_workspace: project_workspace,
  package: read_node("package_checks"),
  project: read_node("project_checks")
])
