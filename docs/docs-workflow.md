# Documentation Workflow

The repository uses MkDocs with the Material theme to convert Markdown content and Mermaid diagrams into a browsable site. This page summarizes the tooling expectations for contributors.

## Dependencies

| Tool | Purpose | Installation Notes |
|------|---------|--------------------|
| Python ≥ 3.9 | MkDocs + plugins | `pip install -r docs/requirements.txt` |
| Node.js ≥ 18 | Mermaid CLI | `npm install -g @mermaid-js/mermaid-cli` *(optional when using `npx`)* |
| Make | Automation entry point | Included on most Linux distros and macOS |

The `docs/requirements.txt` file pins a baseline for MkDocs packages. Install them into a virtual environment to avoid polluting system Python.

## Local Authoring

- Edit Markdown under the `docs/` directory. The navigation menu is defined in `mkdocs.yml`.
- Place Mermaid sources next to the page they support (for example, `docs/diagrams/*.mmd`).
- Run `make docs-serve` while iterating. This regenerates all diagrams, starts `mkdocs serve`, and binds to `0.0.0.0:8000` for remote previews.

### Diagram Conventions

- Output format defaults to SVG so diagrams remain crisp when zoomed inside the Material theme.
- Keep diagrams focused and reference them from the relevant pages using standard Markdown image syntax.
- When diagrams reference Kubernetes objects, stick to namespace/name notation (e.g., `awx/awx-operator`).

## Continuous Integration

GitHub Actions execute the following steps on every push to `main`:

1. Install MkDocs Material, the Mermaid plugin, and Mermaid CLI dependencies.
2. Run `make docs` to regenerate all diagrams and ensure the MkDocs build succeeds with `--strict` mode.
3. Deploy the rendered site to the `gh-pages` branch via `mkdocs gh-deploy`.

Pull requests run through steps 1-2 to validate documentation without publishing.

## Pre-commit Hook

A [`pre-commit`](https://pre-commit.com/) hook is provided to help contributors catch stale diagrams before they push commits. Install the framework (`pip install pre-commit`) and then enable it:

```bash
pre-commit install
```

On each commit, the hook triggers `make docs`. Regenerated SVGs will show up as staged changes if diagrams or Markdown were modified.
