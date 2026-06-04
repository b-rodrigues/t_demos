# Pipeline Visualization & Dry-Run Demo

This demo exercises the browser-based visualization tools and cache-aware dry-run plan serialization features of T-Lang pipelines.

## Features Exercised

1. **Cache-Aware Dry Runs**:
   - `build_pipeline(p, dry_run = true)` returns a structured DataFrame (`node`, `action`, `store_path`).
   - Action categories are verified to be `"rebuild"` for unbuilt/modified pipeline nodes, and `"cache_hit"` for previously cached/built pipeline nodes.

2. **Mermaid Browser Visualization**:
   - `show_plot(p)` dynamically transforms a T-Lang `Pipeline` dependency graph into a structured Mermaid diagram, renders it into a browser-openable temporary HTML page styled with rich modern design elements, and opens it.
   - `show_plot("graph TD ...")` detects and renders custom Mermaid graph definition strings in the browser.
