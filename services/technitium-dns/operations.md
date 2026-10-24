# DNS Operations

Use this runbook with the [DNS configuration] and [observability service]
instructions. Operate from the correct root and its existing authoritative
state. Importing successfully is not permission to apply a plan.

## Verified Scope

Adoption was verified against Technitium 15.6.2, OpenTofu 1.13.1, and the pinned
Technitium provider 1.3.0. The DNS root owns its existing Incus instance, 26
explicit server-setting fields, three unsigned Primary zones, and 16 static
records. Observability owns two records in its own state. All 24 records are
accounted for: 18 managed A/CNAME/PTR records and six operator-owned apex SOA/NS
exclusions. The [ownership table] gives the central legacy fallback reasons.

The zone resource does not own an exhaustive record set. Unrepresented server
settings, web/authentication, full SOA/apex NS data, transfer/notify/TSIG settings,
and application files remain operator-managed. Do not approximate unsupported
configuration or change DNS names to satisfy provider validation.

Recorded live evidence covers [settings adoption], [zone adoption], and
[record adoption]. Final read-only verification on 24 October 2026, against
runtime revision `2a17ebe`, reconciled API inventory, private declarations, and
both states with one owner per recordset. It found:

- Exit-`0` DNS-scoped plans for all 26 settings, three zones, and 18 records.
- All 48 service-side authoritative UDP/TCP answers unchanged, including six
  reverse-lookup checks; settings, apex data, and zone policies unchanged.
- External positive and random-name negative resolution over UDP/TCP. The
  negative SOA response agreed with a direct query to the configured HTTPS
  forwarder. No cache flush or configuration change was needed.
- No application configuration changes, restart, or state ownership changes.

The probes ran through the server's DNS Client API with `server=this-server`
and `import=false`. They do not establish a separate client-network path or
packet-level upstream selection. No pre-adoption external-forwarding response
baseline exists; current forwarding works and its adopted settings are unchanged.
Internet response TTLs and address order are not stable comparison values.

No signed zones, FWD records, or multi-value recordsets occur in the current
inventory. Do not add signing or conditional-forwarding changes merely to test
them. Separate sandbox tests covered sibling-safe create/update/delete,
service-record recreation, and state-only ownership handoff; these are not
production destructive tests.

## DNS-only Verification Exception

The operator deferred pre-existing observability cloud-init drift. A full-root
plan proposes snippet replacement and replacement of all three VMs; it must not
be applied for DNS work. No permanent `ignore_changes` rules or bootstrap edits
were added to make adoption pass. Resolving that drift is separate work.

For this deployment, review saved DNS-scoped plans from each existing root:

```bash
# From services/technitium-dns
tofu plan -detailed-exitcode -out=dns-review.tfplan \
  -target=technitium_server_settings.existing \
  -target=technitium_zone.managed \
  -target=technitium_record.managed
tofu show dns-review.tfplan

# From services/observability-warehouse
tofu plan -detailed-exitcode -out=dns-review.tfplan \
  -target=technitium_record.managed
tofu show dns-review.tfplan
```

Planning is an authorized online operation. Exit `0` means no changes, `2`
means changes need review, and `1` is an error. Targeting emits a warning because
it omits the rest of the root: it proves DNS convergence only. Preserve the
known full-root exception in the evidence rather than calling the root clean.
Return to full-root verification after the separate drift is resolved.

## Routine Changes and Drift Review

1. Use protected private inputs and an authorized token. Central settings/zones
   require admin-level access; record-only consumers need zone View, Modify,
   and Delete. Include reverse zones for PTR records. These are zone-wide
   privileges, not per-service record isolation. Keep TLS verification enabled;
   use `TECHNITIUM_CACERT` or `TECHNITIUM_CAPATH` for a private CA.
2. Reconcile the current API inventory, declarations, and state in both roots
   before a change. Each name/type recordset, including every sibling value,
   has one root owner. New dynamic/generated entries stay with their existing
   owner until an explicit transfer. Refresh the [ownership table] when roles
   change; do not guess service identity from an abbreviation.
3. Change only the owning service's private record inputs. Preserve Grafana's
   proxy-routed CNAME target unless changing ingress is the explicit task.
   Keep `overwrite=false`; match sibling TTLs. Omitted/null comments stay
   server-managed; `""` clears them. Never apply a create to adopt an existing
   entry; use the [import procedure] and skip exact bindings on reruns.
4. Back up the application and affected states, validate locally, then generate
   and privately inspect a fresh saved plan for the agreed scope. State and
   JSON plans can reveal credentials and locators even when marked sensitive.
   Stop on an unexpected deletion, replacement, duplicate owner, or field drift.
5. Obtain separate apply approval. Before applying, confirm the saved plan,
   source, inputs, state, and live baseline have not changed. Apply only that
   reviewed plan, not an unsaved plan or the deferred infrastructure plan.
6. Compare records, comments, TTLs, SOA/NS data, zone policies, and relevant
   UDP/TCP answers. Require a final exit-`0` plan for the agreed scope. Use a
   known allowed external query for forwarding; distinguish cache effects from
   an actual failure and never enable record import in the DNS Client API.

Deletion follows ownership: removing a service's record entry deletes that
record, not the shared zone. Removing a guest alone does not remove an
independent DNS declaration. Zone deletion/replacement removes **all** its
records, including service-owned and unmanaged entries. `prevent_destroy`
protects a declared zone, not against direct API deletion, removed declarations,
or lost state. Neither it nor Proxmox protection is a backup.

For a [legacy-to-service transfer], freeze both roots, back up both states,
release the old binding without deleting the record, and import into the new
owner. Never bind it in both states or apply in the gap. Move the whole
recordset and related forward/reverse entries together. On failure, retain the
freeze and restore the old declaration/binding rather than recreate live DNS.
This sequence and exact-binding reruns were exercised in the isolated sandbox.

## Backup and Recovery

### Keep Separate Recovery Artifacts

| Artifact | Recovers | Does not recover |
| --- | --- | --- |
| Technitium application archive | Exported authentication, settings, zones, and selected application data | OpenTofu ownership or the guest/image itself |
| Each root's state snapshot | Resource bindings, lineage, serial, and state-held attributes | Authoritative DNS contents or operator-managed settings |
| Code, lock files, and protected inputs/credential access | Desired supported subset and provider access | Full server identity, apex data, or a complete application backup |

Pause concurrent operations while taking state snapshots and record the root,
code revision, workspace, and application backup they belong to. Keep artifacts
private, outside the checkout and outside the instance being protected. Local
snapshots alone do not survive workstation/storage loss. Destination, retention,
and scheduling remain operator choices, not new adoption prerequisites.

Use Technitium's backup/export controls to include authentication, web service,
DNS and log settings, zones, allowed/blocked lists, and block-list caches. Include
DHCP scopes, apps, cluster data, and external certificate/key files when used;
do not assume a configuration archive contains every external file. The original
inventory had no apps, clustering, or external certificate files and one
disabled DHCP scope. Recheck coverage if features change. Do not enable
clustering as part of recovery.

Validate each ZIP archive's CRC before relying on it. CRC success detects
corruption; it does not prove completeness or usable operator credentials.
Archives and state may contain authentication material. Never attach them,
raw DNS exports, populated tfvars, or plans to Git, Linear, or a PR.

### Snapshot Each Authoritative State

Run from each existing service root after selecting a private, existing backup
parent through `SNAPSHOT_PARENT`. It must be outside the checkout. This command
retains a protected partial file on export/validation failure and promotes it
only after basic format validation; do not use an unvalidated partial file.

```bash
(
  set -euo pipefail
  umask 077
  : "${SNAPSHOT_PARENT:?Select an existing private backup directory outside Git}"
  snapshot_dir="$(mktemp -d "${SNAPSHOT_PARENT%/}/dns-state.XXXXXXXX")"
  partial="$snapshot_dir/terraform.tfstate.partial"
  tofu state pull > "$partial"
  python3 - "$partial" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    state = json.load(source)
if not isinstance(state, dict):
    raise SystemExit("State must be a JSON object; partial snapshot retained")
if state.get("version") != 4:
    raise SystemExit("Unexpected state format; partial snapshot retained")
if not isinstance(state.get("lineage"), str) or not state["lineage"]:
    raise SystemExit("Missing state lineage; partial snapshot retained")
if type(state.get("serial")) is not int or state["serial"] < 0:
    raise SystemExit("Invalid state serial; partial snapshot retained")
resources = state.get("resources")
if not isinstance(resources, list) or not resources:
    raise SystemExit("Missing resource inventory; partial snapshot retained")
if not all(isinstance(resource, dict)
           and resource.get("mode") in ("managed", "data")
           and all(isinstance(resource.get(key), str) and resource[key]
                   for key in ("type", "name"))
           and isinstance(resource.get("instances"), list)
           for resource in resources):
    raise SystemExit("Incomplete resource inventory; partial snapshot retained")
PY
  chmod 600 "$partial"
  mv -- "$partial" "$snapshot_dir/terraform.tfstate"
)
```

This checks a snapshot's shape, not whether it is the correct or newest state.
Record its private location and verify its lineage, serial, and resource
addresses against the root before recovery. Restoring an older snapshot can
discard ownership transfers made since it was taken.

### State Recovery

1. Freeze applies/imports in both roots and preserve any current state. Identify
   the correct root, backend/workspace, code revision, inputs, and snapshot.
2. Copy the candidate snapshot into a **new isolated directory**, mode `0600`.
   Inspect its JSON metadata and use `tofu state list -state=<snapshot-path>`
   privately to compare expected bindings. Confirm lineage, serial, and contents
   survived the copy. Parsing successfully does not authorize promotion.
   A later `state pull` without the original root configuration can change
   validation-check metadata; retain the original copy and verify resource
   bindings, lineage, serial, and outputs independently of that metadata.
3. Reconcile live resources and both roots' current ownership. If only a binding
   was lost, consider reimporting that existing identity rather than replacing
   the whole state. Do not create an already-existing record to repair state.
4. With explicit state-recovery approval and a protected copy of the current
   state, restore through the backend's normal guarded mechanism. For local
   state, `tofu state push` rejects conflicting lineage/newer serials. Stop on
   such a rejection; do not use force or overwrite another owner's state.
5. Review fresh plans for the agreed scope, reject unintended creates/deletes,
   and verify DNS answers before releasing the freeze. Do not replay a saved
   pre-recovery plan.

### Application Recovery

1. Preserve current artifacts and identify the intended archive and compatible
   server version. Losing the instance's root disk loses `/etc/dns`; state alone
   cannot rebuild its operator-managed contents. A future guest rebuild also
   needs an available image source: an old fingerprint may no longer be cached.
2. Restore first in a fresh rootless sandbox with network `none`, no published
   ports, and separate state/inputs. Do not advertise restored DNS/DHCP or
   contact cluster peers. Perform restore requests inside its network namespace.
3. Create a **distinct temporary recovery administrator** before restoring
   authentication and web settings. The restore retains the restoring identity
   and replaces any backed-up user with the same username. Do not reuse the
   original administrator's name or treat a provider token as a recovery login.
4. Restore the required application categories and reconnect through the
   restored API/listener settings. Check authentication, settings, all zones,
   records/apex data, enabled/disabled scopes, and any used apps/certificates.
   Verify intended operator access before removing the temporary administrator.
5. In isolation, compare UDP/TCP answers and restart the restored sandbox to
   verify persistence. Keep restored credentials, exports, and logs private.
   Network-none recovery cannot establish external forwarding or client routing.
6. Obtain separate production recovery/cutover approval. Preserve the existing
   root ownership, repair state only if needed, and reconcile plans against the
   recovered application **before** applying: stale desired inputs can overwrite
   the restored settings. Verify the secure API, zone permissions, client DNS,
   reverse lookups, and live forwarding after the approved cutover.

Earlier isolated recovery evidence verified CRC, authentication/web restoration,
a fresh temporary-administrator login, and persistence across restart. Original
operator-password login and complete production recovery were not tested.
State copy/restore preserved lineage, serial, addresses, and mode `0600` in an
isolated directory; export failure, invalid JSON, and missing-field checks did
not promote partial snapshots. Later isolated adoption tests also verified 48
UDP/TCP answers and restart persistence. These are bounded recovery evidence,
not permission to restore over production.

### Rollback and Provider Upgrades

For an incorrect configuration change, preserve evidence, compare the actual
live state, then review a new plan restoring the intended values. Reverting Git
or rolling back state alone does not undo a server write. A deleted zone may
need application recovery, including records owned in other roots. Re-import
restored identities rather than applying conflicting creates.

Keep the provider pinned. Before an upgrade, review schema/default/import and
identity changes, then exercise import/refresh/update/delete in an isolated
restore with siblings, comments, apex exclusions, and both owning roots. Recheck
required permissions and no-change plans. Never rename data, reset credentials,
or change signing/transfer policy just to accommodate a new provider.

[DNS configuration]: README.md
[observability service]: ../observability-warehouse/README.md
[ownership table]: README.md#ownership
[import procedure]: README.md#import-and-reconcile
[legacy-to-service transfer]: README.md#transfer-a-legacy-record-to-a-service
[settings adoption]: https://github.com/lexedwards/homelab/pull/4#issuecomment-6385346045
[zone adoption]: https://github.com/lexedwards/homelab/pull/5#issuecomment-6387763498
[record adoption]: https://github.com/lexedwards/homelab/pull/6#issuecomment-6389066112
