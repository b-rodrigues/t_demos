#!/usr/bin/env bash
# script to rebuild the demos site in docs/
set -e

DEMOS_ROOT=$(pwd)
DOCS_DIR="$DEMOS_ROOT/docs"

echo "=== T Demos Site Rebuilder ==="
mkdir -p "$DOCS_DIR"
# Clean up but keep the directory
rm -rf "$DOCS_DIR"/*

# Template for index.qmd
INDEX_QMD="$DOCS_DIR/index.qmd"
cat <<EOF > "$INDEX_QMD"
---
title: "T Language Demos"
format:
  html:
    theme: cosmo
    toc: true
---

Welcome to the collection of **T** pipeline demos. This site is self-contained and showcases various features of the T language for data science orchestration.

## List of Demos

EOF

# Loop over each directory in t_demos
for demo_dir in */; do
    # Skip directories that don't look like T projects or are special
    if [ ! -f "${demo_dir}tproject.toml" ] || [ "$demo_dir" == "docs/" ] || [ "$demo_dir" == "_extensions/" ]; then
        continue
    fi
    
    demo_name=$(basename "$demo_dir")
    entry_point=$(ls "${demo_dir}"src/*.t 2>/dev/null | head -n 1)
    
    if [ -n "$entry_point" ]; then
        echo "--> Building demo: $demo_name"
        
        # Absolute paths for T
        ABS_ENTRY=$(realpath "$entry_point")
        ABS_DEMO_ROOT=$(realpath "$demo_dir")
        
        cd "$ABS_DEMO_ROOT"
        
        # 1. Provision the tlang Quarto extension from the root _extensions
        mkdir -p src/_extensions
        rm -rf src/_extensions/tlang
        cp -r "$DEMOS_ROOT/_extensions/tlang" src/_extensions/
        
        # 2. Clean previous build artifacts and run the pipeline
        rm -rf pipeline-output/ _pipeline/
        
        # Assuming tools are available on CI via flakes
        nix develop github:b-rodrigues/tlang --command t update
        nix develop --command t run --unsafe "$ABS_ENTRY"
        
        # 3. Extract metadata from tproject.toml
        description=$(grep "^description =" tproject.toml | head -n 1 | sed 's/description = "//;s/"$//')
        if [ -z "$description" ]; then description="A T demonstration project."; fi
        
        # 4. Extract node names from the DAG metadata
        nodes=$(jq -r '.[].node_name' _pipeline/dag.json)
        
        # 5. Generate a dedicated documentation page for this demo
        DOC_QMD="src/docs_rendered.qmd"
        cat <<EOF > "$DOC_QMD"
---
title: "$demo_name"
format:
  html:
    theme: cosmo
    toc: true
filters:
  - tlang
---

$description

## Nodes in this Pipeline

Below is the state of each node in the pipeline after execution.

EOF

        # Add a chunk for each node
        for node in $nodes; do
            cat <<EOF >> "$DOC_QMD"
### Node: \`$node\`

\`\`\`{t}
read_node("$node")
\`\`\`

EOF
        done
        
        # 6. Render the documentation page using the demo's environment
        nix develop --command quarto render "$DOC_QMD" --to html
        
        # 7. Move the rendered output to the global docs directory
        mkdir -p "$DOCS_DIR/demos/$demo_name"
        mv "src/docs_rendered.html" "$DOCS_DIR/demos/$demo_name/index.html"
        if [ -d "src/docs_rendered_files" ]; then
            mv "src/docs_rendered_files" "$DOCS_DIR/demos/$demo_name/"
        fi
        
        # 8. Update the main index
        echo "- [$demo_name](demos/$demo_name/index.html): $description" >> "$INDEX_QMD"
        
        # Cleanup
        rm -f "$DOC_QMD"
        
        cd "$DEMOS_ROOT"
    fi
done

# Finally, render the main index using one of the available environments
echo "=== Rendering Main Index ==="
# Find any valid project directory to use its nix develop environment
any_demo=""
for d in */; do
    if [ -f "${d}tproject.toml" ] && [ "$d" != "docs/" ] && [ "$d" != "_extensions/" ]; then
        any_demo="$d"
        break
    fi
done

if [ -n "$any_demo" ]; then
    cd "$DEMOS_ROOT/$any_demo"
    nix develop --command quarto render "$INDEX_QMD" --to html
    cd "$DEMOS_ROOT"
else
    echo "    ! No valid T projects found to render the index"
fi

echo ""
echo "Success! The self-contained T Demos site is now at: $DOCS_DIR/index.html"
