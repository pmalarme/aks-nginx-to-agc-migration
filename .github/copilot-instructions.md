# GitHub Copilot Instructions

Thanks for helping build the AKS NGINX ➜ AGC migration toolkit! Please keep these guardrails in mind when suggesting code or docs:

## Repository scope
- Scripts live at the repo root and are intended to be runnable end-to-end from a fresh shell session on Ubuntu 22.04.
- Supporting helpers belong under `scripts/` and documentation under `docs/` unless there is a strong reason otherwise.
- We assume Azure CLI, Helm, kubectl, and Python 3 are available (or installed by our scripts). Avoid introducing other language runtimes or package managers.

## Coding style
- Bash scripts should be POSIX-compatible where possible, use `set -euo pipefail`, and print clear status messages before executing long-running Azure commands.
- Prefer multi-line commands with trailing backslashes for clarity (`az`, `helm`, `kubectl`). Always quote variable expansions.
- Python utilities should rely on the standard library only and support both CLI flags and environment variables.

## Documentation
- Keep the README as the single source of truth for the migration workflow. Add deeper explanations in `docs/` rather than bloating the README.
- When updating scripts, ensure the README and relevant doc sections stay in sync (step names, file paths, prerequisites).
- Favor GitHub-flavored Markdown features (details blocks, tables, callouts) for clarity.

## Testing & validation
- For shell scripts, include a short "Test" section or final command that demonstrates success (e.g., `kubectl get ingress`).
- When comparing behavior between ingress paths, reuse the `03-test-agc-ingress.sh` helper instead of writing bespoke diff logic.

## Security & secrets
- Never hardcode credentials, subscription IDs, or private endpoints. Use variables (`$RESOURCE_GROUP_NAME`, `$AKS_NAME`) and document expected values.
- Use managed identities and workload identity flows; avoid service principal secrets or certificates.

## Pull request guidance
- Keep changes focused: update scripts and docs together to maintain accuracy.
- Preserve existing script names and semantics; add new capabilities behind flags or environment variables.
- Include sample command output in PR descriptions when relevant (Azure CLI, kubectl, curl).

If in doubt, err on the side of clarity and reproducibility. Thanks for the assist!
