# {{name}} — agent instructions

This file is the repository's own layer. The harness instruction file is RENDERED from the governance
layers plus this file (`governance render`); never edit a rendered file by hand.

- **Lane:** `{{name}}`. One agent seat owns changes to this repository; anyone else proposes through
  their own branch and a pull request.
- **Integration branch:** work lands on a feature branch, integrates into this lane's integration
  branch, and reaches the default branch through ONE open pull request — never a direct push. The
  rule, and how the integration branch is named, come from the governance layers this file is
  rendered with; this file does not restate them.
- **Deploys** from this repository are status-gated on the default branch: `README.md` → *How to deploy*.
- **The repository stands alone.** Keep the stack-repo properties true in every change:
  `technical.md` → *A deployable repo stands alone — the stack-repo properties*.
