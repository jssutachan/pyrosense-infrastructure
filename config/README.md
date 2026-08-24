# Configuration

Environment configuration that is not committed, plus versioned templates
for it.

## Convention

Any gitignored file required to run the project ships an `.example`
counterpart in this directory. Without it, a fresh clone cannot know which
fields the missing file needs.

| Template (committed) | Real file (gitignored) |
|---|---|
| `backend.hcl.example` | `backend.hcl` |

## Why the backend config is not committed

The state bucket name is suffixed with the AWS account ID to guarantee global
uniqueness. Committing it would publish the account ID in a public repository:
low severity on its own, but free reconnaissance, and a violation of the
project's "no hardcoded accounts, ARNs or endpoints" standard.

Partial backend configuration also keeps the code reusable across accounts
without editing it.