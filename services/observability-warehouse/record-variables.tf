variable "technitium_server_url" {
  description = "Private DNS API base URL using verified HTTPS or a separately reviewed secure access path. Authentication uses TECHNITIUM_API_TOKEN."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = can(regex("^https?://[^[:space:]]+$", var.technitium_server_url))
    error_message = "technitium_server_url must be an HTTP(S) API base URL without whitespace."
  }
}

variable "technitium_records" {
  description = "Service-owned DNS records: collector (A) and grafana_alias (CNAME to the shared proxy, not the guest). Names, values, and TTLs are explicit private inputs. Empty means no record ownership. Omitted/null comments remain server-managed."
  type = map(object({
    zone     = string
    name     = string
    type     = string
    value    = string
    ttl      = number
    comments = optional(string)
  }))
  sensitive = true
  nullable  = false

  validation {
    condition = alltrue([
      for label, record in var.technitium_records : try(
        lookup({ collector = "A", grafana_alias = "CNAME" }, label, "unsupported") == record.type &&
        alltrue([for value in [record.zone, record.name, record.value] : length(trimspace(value)) > 0 && value == trimspace(value) && !strcontains(value, "::")]) &&
        record.ttl >= 0 && record.ttl <= 2147483647 && floor(record.ttl) == record.ttl,
        false
      )
    ])
    error_message = "Declare only collector (A) and grafana_alias (CNAME), with nonblank private identities and integer TTLs from 0 through 2147483647."
  }

  validation {
    condition = try(length(distinct([
      for record in values(var.technitium_records) : lower(trimsuffix(record.name, "."))
    ])) == length(var.technitium_records), false)
    error_message = "The collector and Grafana alias must use distinct DNS names."
  }

  validation {
    condition = try(alltrue([
      for record in values(var.technitium_records) :
      lower(trimsuffix(record.name, ".")) == lower(trimsuffix(record.zone, ".")) ||
      endswith(lower(trimsuffix(record.name, ".")), ".${lower(trimsuffix(record.zone, "."))}")
    ]), false)
    error_message = "Each record name must be within its explicitly supplied parent zone."
  }
}
