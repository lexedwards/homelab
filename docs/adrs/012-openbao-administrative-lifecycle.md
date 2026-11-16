---
name: Separate OpenBao deployment, hardening and account lifecycles
status: accepted
---

# Separate OpenBao Administrative Lifecycles

## Context

The deployed OpenBao server is already initialized. Its infrastructure must remain
manageable while the API is sealed or unavailable. The shared AppRole root
previously assumed an administrative identity existed but did not configure one.
Root tokens should be used only for enough bootstrap to establish non-root
administration, then explicitly revoked after that administration is verified.

## Decision

Use three sibling roots under `services/openbao/`:

- `init/` owns the existing infrastructure and first-boot configuration. The name
  does not authorize running `bao operator init` again. Initialization, independent
  share custody and manual unseal remain separate operator actions.
- `hardening/` owns shared authentication backends and administrative policy.
  Initial bootstrap uses the original root token; ongoing changes use non-root
  administration. The former `authorization/` state moves here unchanged.
- `accounts/` owns identity metadata and policy assignments for people, systems
  and machine accounts without another service's IaC owner. Service-specific
  roles and policies remain with their service under ADR 002. No speculative
  machine identities are provisioned.

Use userpass for the named personal administrator. Store its unique password in
Proton Pass. Password enrollment, login, issued tokens and root revocation stay
outside OpenTofu and cloud-init. Future CI/CD uses separate machine identities.

Vault provider 5.13.0's dedicated user resource requires a password or password
hash even though its fields are write-only. Use a metadata-only generic endpoint
for the externally enrolled user instead, with refresh enabled and deletion
guarded. Do not pass passwords through OpenTofu. Bootstrap enrollment attaches
the hardening-owned policy once; accounts adopts and owns ongoing token metadata
using the freshly authenticated non-root administrator.

Administrative roots use the provider's native `VAULT_TOKEN` environment channel,
replacing redundant ephemeral token variables and explicit provider assignments.
CLI login caches a token but does not export it. Both planning and saved-plan
apply require valid, privileged credentials. This supersedes ADR 008's input-channel
choice only; its trusted administrative ownership boundary remains unchanged.
Service-specific enrollment-issuer credentials are a separate boundary.

Verify fresh non-root administrative reads and writes before separately authorized
revocation of the original root token. `revoke -self` must run with that original
token selected, never with the replacement administrator token. Keep independent
unseal custody and emergency quorum recovery.

## Consequences

- Hosting resource addresses, provider versions and state contents do not change.
  A guarded local-file migration preserves default/named-workspace states, backend
  metadata and private inputs; it does not apply infrastructure or import resources.
- Initial enrollment requires a short, explicitly authorized root session. Account
  adoption and ongoing hardening run non-root. No stage silently performs another.
- The administrator can manage authorization and can therefore grant additional
  rights. Its policy is not a hostile-administrator isolation boundary and does not
  directly grant secret-value access or root-only recovery operations.
- Local schema checks and isolated native fixtures do not establish production
  authentication, root revocation, worker acceptance or warehouse readiness.

See the [service runbook](../../services/openbao/README.md) for migration and
operator procedures, and [ADR 008](008-openbao-administrative-authorization.md)
for administrative versus value-enrollment ownership.
