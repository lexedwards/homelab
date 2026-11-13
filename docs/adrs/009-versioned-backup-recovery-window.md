---
name: Interpret versioned backup retention as a recovery window
status: accepted
---

# Interpret Versioned Backup Retention as a Recovery Window

## Context

The existing backup bucket is versioned. An ordinary object deletion can hide the
current object while retaining noncurrent versions and delete markers, so logical
retirement does not establish permanent erasure.

## Decision

Preserve versioning and interpret fourteen-day retention as a recovery window,
not a hard permanent-purge deadline. Review lifecycle cleanup of noncurrent
versions and delete markers, including its grace period, separately.

## Consequences

- Recoverable data can remain beyond the managed recovery window; storage usage
  and permanent-erasure claims need their own reviewed policy.
- Ordinary backup access does not silently gain version-purge or bucket-admin
  privileges.
- Preserve recovery-token material associated with retained versions until their
  disposition is reviewed; logical deletion alone does not justify dropping it.
