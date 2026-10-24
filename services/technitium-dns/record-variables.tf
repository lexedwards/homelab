variable "technitium_records" {
  description = "DNS administration and explicitly classified legacy records keyed by stable opaque labels. Empty means no record ownership. Import existing records once; new records use the same resources. Omitted/null comments remain server-managed."
  type = map(object({
    zone      = string
    name      = string
    type      = string
    value     = string
    ttl       = number
    comments  = optional(string)
    ownership = string
  }))
  sensitive = true
  nullable  = false

  validation {
    condition = alltrue([
      for label, record in var.technitium_records : try(
        can(regex("^[a-z][a-z0-9_]*$", label)) &&
        alltrue([for value in [record.zone, record.name, record.value] : length(trimspace(value)) > 0 && value == trimspace(value) && !strcontains(value, "::")]) &&
        contains(["A", "CNAME", "PTR"], record.type) &&
        record.ttl >= 0 && record.ttl <= 2147483647 && floor(record.ttl) == record.ttl &&
        contains(["dns_administration", "legacy_compute_store", "legacy_shared_ingress", "legacy_untracked_service", "legacy_unconfirmed_application"], record.ownership),
        false
      )
    ])
    error_message = "Records require opaque snake_case labels, nonblank identities, an A/CNAME/PTR type, an integer TTL from 0 through 2147483647, and an explicit administration or legacy ownership classification."
  }

  validation {
    condition = try(length(distinct([
      for record in values(var.technitium_records) : jsonencode([
        lower(trimsuffix(record.zone, ".")), lower(trimsuffix(record.name, ".")), record.type, lower(trimsuffix(record.value, "."))
      ])
    ])) == length(var.technitium_records), false)
    error_message = "Each record identity must have exactly one owner, ignoring DNS case and trailing dots."
  }

  validation {
    condition = try(alltrue([
      for record in values(var.technitium_records) :
      lower(trimsuffix(record.name, ".")) == lower(trimsuffix(record.zone, ".")) ||
      endswith(lower(trimsuffix(record.name, ".")), ".${lower(trimsuffix(record.zone, "."))}")
    ]), false)
    error_message = "Each record name must be within its explicitly supplied parent zone."
  }

  validation {
    condition = try(alltrue(flatten([
      for left in values(var.technitium_records) : [
        for right in values(var.technitium_records) :
        lower(trimsuffix(left.zone, ".")) != lower(trimsuffix(right.zone, ".")) ||
        lower(trimsuffix(left.name, ".")) != lower(trimsuffix(right.name, ".")) ||
        (left.type != "CNAME" && right.type != "CNAME" && (left.type != right.type || left.ttl == right.ttl)) ||
        (left == right)
      ]
    ])), false)
    error_message = "Sibling records of the same type must agree on TTL; a CNAME cannot coexist with another declared record at its name."
  }
}
