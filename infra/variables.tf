variable "name" {
  description = "Prefix used for resource names."
  type        = string
  default     = "log-processor"
}

variable "vpc_id" {
  description = "ID of the existing VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets in at least two availability zones."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Provide at least two private subnets for high availability."
  }
}

variable "instance_type" {
  description = "Worker instance type; tune after load testing."
  type        = string
  default     = "t3.small"
}

variable "min_size" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 10
}

variable "desired_capacity" {
  type    = number
  default = 2
}

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "target_backlog_per_instance" {
  description = <<-EOT
    Messages waiting per in-service worker that the scaling policy holds steady.
    Derive it from the latency budget rather than guessing:
    target = acceptable_seconds_of_backlog * messages_per_second_per_instance.
    Example: a worker draining 20 msg/s with a 30s budget gives 600.
  EOT
  type        = number
  default     = 600

  validation {
    condition     = var.target_backlog_per_instance > 0
    error_message = "Target backlog per instance must be greater than zero."
  }
}

variable "noncurrent_version_retention_days" {
  description = <<-EOT
    Days to keep superseded object versions before deleting them permanently.
    Versioning here guards against accidental overwrite of an archived object,
    not long-term history, so this is deliberately much shorter than
    log_retention_days.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_retention_days > 0
    error_message = "Noncurrent version retention must be greater than zero."
  }
}
