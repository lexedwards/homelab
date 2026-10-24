---
name: principle-configuration-values
description: Classifies what is safe to commit, what belongs in local tfvars or environment variables, and what deserves a sensible default. Use when authoring or reviewing OpenTofu variables, provider authentication, terraform.tfvars.example, or configuration documentation in this repository.
---

# Configuration Values

**Rule:** Commit reusable configuration intent and safe defaults; supply protected
or deployment-specific values through ignored local inputs, choosing tfvars for
stable deployment configuration and environment variables for credentials or
execution-specific inputs.

This principle owns configuration classification, input channels, defaults, and
the example-file contract across host and service roots. It does not authorize
reading local deployment values or running infrastructure operations. Application
credential enrollment and state-exposure decisions belong to
[Lifecycle And Operations](../create-a-service/references/lifecycle-and-operations.md).

## Decide What Can Be Committed

Classify each value before choosing its input channel:

| Value | Tracked representation | Actual value |
| --- | --- | --- |
| Password, token, private key, or application credential | Variable declaration and blank commented required assignment; never a working credential | Prefer an approved secret store or environment injection; ignored local tfvars is acceptable when a variable input is unavoidable |
| Exact deployment locator: address, CIDR, gateway, DNS value, VLAN/guest ID, API/remote/storage endpoint, local path, datastore identifier, username, or public key | Typed variable without a deployment-specific default; blank commented assignment | Prefer ignored local tfvars; environment injection is also supported |
| Established non-secret architecture: host roles, project/pool/bridge/datastore/service-name conventions | Code, documentation, and safe defaults where already established in tracked files | Override locally only when needed |
| Reusable behavior: resource sizing, retention, package versions, feature flags | Literal/local for an invariant; typed variable with a sensible default for an operator choice | Omit unless overriding the default |

Do not promote ignored or untracked values into repository conventions. Preserve
useful architecture already established in tracked files rather than treating
every hostname-like string or identifier as secret. Loopback addresses are fine
for in-guest readiness checks.

Never disclose secrets. Never commit state, saved plans, rendered first-boot data,
populated local tfvars, credential files, or environment files containing protected
values. Do not inspect ignored local configuration or runtime artifacts to discover
deployment values.
Read exact locators only when the authorized task requires them; do not repeat
them in chat, documentation, tests, examples, commits, or PRs. Use semantic
placeholders outside tfvars examples.

## Choose The Input Channel

- **Prefer tfvars:** stable deployment topology and structured inputs such as node
  maps, template/guest IDs, endpoint locators, storage, SSH public keys, and local
  overrides. Use ignored `terraform.tfvars` or an explicitly selected ignored
  `*.tfvars` file. Verify ignore coverage; never force-add a populated file.
- **Prefer environment injection:** credentials, CI-supplied values, and temporary
  execution context. Use provider-native environment variables when the pinned
  provider supports them and the provider configuration permits that fallback;
  otherwise use `TF_VAR_<variable_name>` for declared OpenTofu inputs.
- **Either channel:** any declared input may use tfvars or `TF_VAR_...` when its
  type and validation accept the value. Prefer tfvars for readable maps/lists;
  follow OpenTofu's expression syntax when encoding complex environment inputs.
  A provider-native environment variable is not a root-module input and cannot
  satisfy a required variable declaration by itself.
- Document the supported authentication path and required variable names without
  embedding actual values in shell commands, logs, or tracked `.env` files.
  Environment injection is not encryption and does not keep values out of state
  when resources persist them. Mark unavoidable secret inputs/outputs sensitive;
  sensitivity redacts normal output but does not encrypt state.
- Avoid setting the same input in several places. OpenTofu loads `TF_VAR_...`
  before automatically loaded tfvars, so tfvars overrides the environment;
  command-line `-var`/`-var-file` inputs take precedence over those. Do not promise
  an environment override without checking the effective input sources.

## Choose Sensible Defaults

- Put defaults in `variables.tf`, not only in the example or README. Use a
  default when omission gives useful, safe, reusable behavior: conservative
  sizing, retention, pinned supported versions, and secure feature flags.
- Keep credentials, unique IDs, and exact deployment locators required without
  defaults. Do not disguise missing required input with `""`, `[]`, `{}`, fake
  addresses, or invented IDs. An established non-secret architecture convention
  may be a default; a local deployment value may not.
- Use `null` or an empty value only when it has a deliberate, implemented meaning
  such as disabling an optional feature or using a documented fallback. Explain
  that meaning and validate the enabled path. Never default to a working secret
  or silently unauthenticated access.
- Prefer TLS verification and least privilege. Do not copy an insecure setting
  from the reference example merely to match its style. A required exception
  needs a documented reason, not a new general default.
- Give variables explicit types, useful descriptions, and validation for their
  accepted domain. Use `nullable = false` when null has no supported meaning.
  Keep true implementation invariants in code rather than exposing every literal.

## Construct terraform.tfvars.example

Read [the observability-warehouse example](../../../services/observability-warehouse/terraform.tfvars.example)
as the style reference, not as a source of defaults or deployment values.

- Start with a short instruction to copy to `terraform.tfvars`, assign required
  values, and never commit the populated file.
- Use horizontal comment separators and functional groups: **Provider**, **Core**,
  then service components in operational order. Adapt names and omit groups that
  do not apply; do not force a single-service root into warehouse terminology.
- Within each group, put **Required** before **Optional**, omitting empty
  subsections. Classify by whether the declaration has a default, not by whether
  the value is sensitive. Explain provider-native authentication separately if it
  does not use a declared variable.
- Comment out every assignment, including all lines and braces of complex
  values. Leave required scalar values blank after `=`; show useful map/object
  structure with blank protected fields and empty collections where appropriate.
  An empty collection in a required example is a shape hint, not a valid default.
- Show every operator-facing optional variable with its actual declared default,
  including `null`, booleans, versions, sizes, and deliberately empty values.
  This keeps defaults discoverable without activating redundant overrides when
  the file is copied. Never put realistic secret or locator samples in comments.
- Match the reference's concise verbosity: group labels, aligned nearby
  assignments, complete nested shapes, and brief comments only for non-obvious
  behavior or input-channel choices. Keep full descriptions in `variables.tf` and
  operational explanations in the README.
- Update declarations, example names/types/defaults, and README input instructions
  together. Do not silently reclassify existing defaults merely to style an
  example; flag unsafe behavior for an explicitly scoped implementation change.

## Acceptance Tests

- A new VM ID or storage endpoint is required without a default, blank and
  commented in the example, and supplied locally rather than committed.
- A CPU size or retention choice has a useful declared default, appears commented
  under Optional, and needs no copied override to obtain that default.
- An API token can be injected without a tracked credential; any provider-native
  path actually works with the provider block and required root variables.
- An environment-supplied value is not assumed to override a populated tfvars
  entry. No secret is claimed safe merely because it is sensitive or in an env var.
- A multi-component example stays grouped and fully commented, documents every
  operator-facing input, and agrees with declarations without copying deployment
  values or insecure defaults from the style reference.
