# OpenBao

OpenBao runs on Micro Node with persistent Raft storage, native HTTPS and manual
unseal. **The existing server is deployed and initialized. Never initialize it
again or rerun first boot to adopt this layout.**

## Lifecycle And Ownership

| Root | Owns | Authentication |
| --- | --- | --- |
| [init](init/README.md) | Incus server, durable volume, DNS and first-boot configuration | Independent Incus/DNS credentials; no OpenBao API dependency |
| [hardening](hardening/README.md) | Shared AppRole/userpass mounts and administrative policy | Initial root token only for bootstrap; non-root administration afterwards |
| [accounts](accounts/README.md) | Personal administrator metadata, optional exact-record warehouse credential editing, and identities without another IaC service owner | Named non-root administrator |

Service-specific policies, paths and roles stay with their owning services, per
[ADR 002][ownership]. `accounts/` does not centralize those definitions. Future
machine identities must be separate from the operator's password; none are added
speculatively. See [ADR 012][lifecycle] for the lifecycle and credential boundary.

Initialization, independent unseal-share custody, manual unseal, administrative
bootstrap, verification and root-token revocation remain separate operator stages.
No root automatically applies the next root or issues credentials.

## Preserve Existing Local State

This is a directory migration, not a new deployment. Resource addresses and
provider versions in the hosting root are unchanged. Existing `authorization/`
state belongs to `hardening/`; it must not be imported into a second state.

After the reviewed change is adopted in the canonical checkout on `main`:

1. Stop all OpenTofu commands and other writers. Make a protected backup outside
   Git of existing state, backups, workspace data and private inputs. Keep it
   outside the server's failure domain. Do not print their contents.
2. **Before running OpenTofu in either new root**, run from this directory:

   ```bash
   bash migrate-local-data.sh
   ```

3. The local-only procedure moves existing default state, its backups, named
   workspace states, `.terraform/` (including workspace selection/backend metadata),
   tfvars and override files from the former hosting root to `init/`, and from
   `authorization/` to `hardening/`. It neither reads values nor calls OpenTofu,
   OpenBao or infrastructure APIs. Missing source files are a no-op. It preflights
   both migrations before moving anything, refuses symlinks, destination collisions
   and state-lock markers, and never overwrites a destination. It uses Bash, Git,
   GNU coreutils/find and `flock`.
4. Verify the files against the protected backup privately, including the selected
   workspace. If interrupted, preserve both locations; the completed renames remain
   valid and a rerun moves only the remaining files. Never delete either copy to
   resolve a collision without establishing which is authoritative.
5. Only then run `tofu init -lockfile=readonly` in each migrated root. This is
   OpenTofu backend/provider setup, **not** `bao operator init`. It must retain the
   existing state. Do not accept unexpected backend migration or empty-state
   prompts. Custom `TF_DATA_DIR`, external `-state` paths, external var files and
   custom backend configurations need an explicit path review instead of assuming
   this default-local-state procedure covers them. Review relative paths in private
   inputs/overrides after the move.

Old saved plans are left untouched in their former locations and are **not valid
for adoption**. Generate fresh plans only under separate authorization, from
canonical `main`, using the migrated authoritative state. Stop if a hosting plan
proposes creation, replacement or destruction of the deployed server, volume or
DNS record. No `state rm`, import, resource rename or server operation is needed
for this directory move. Development worktrees must not receive production state.

## Administrative Bootstrap

Follow [hardening](hardening/README.md) to establish userpass and the administrative
policy, then [accounts](accounts/README.md) to enroll the named administrator,
verify non-root management and explicitly retire the initial root token.
Passwords belong in Proton Pass; password enrollment and login stay outside
OpenTofu. Providers consume `VAULT_TOKEN`, available for both planning and
saved-plan apply. `bao login` caches a token but does not export that variable.

Local validation is not live acceptance. Plans/applies, password enrollment,
authenticated checks, credential issuance, token revocation and restarts require
separately scoped authorization. Keep independent recovery access throughout.

[ownership]: ../../docs/adrs/002-openbao-service-configuration-ownership.md
[lifecycle]: ../../docs/adrs/012-openbao-administrative-lifecycle.md
