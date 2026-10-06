variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "zone" {
  description = "GCP zone for zonal cluster"
  type        = string
}

variable "network_policy_mode" {
  description = "NetworkPolicy enforcement: dataplane_v2 for new clusters, calico for existing legacy clusters, or none to explicitly disable enforcement"
  type        = string
  default     = "dataplane_v2"
  nullable    = false

  validation {
    condition     = contains(["dataplane_v2", "calico", "none"], var.network_policy_mode)
    error_message = "network_policy_mode must be one of: dataplane_v2, calico, none. Use none only to explicitly opt out of NetworkPolicy enforcement."
  }
}

variable "datapath_provider" {
  description = "Removed input retained only as a migration guard; remove it and set network_policy_mode explicitly"
  type        = string
  default     = null

  validation {
    condition     = var.datapath_provider == null
    error_message = "datapath_provider is no longer supported. Remove it and set network_policy_mode explicitly: dataplane_v2 for ADVANCED_DATAPATH, calico for legacy clusters with enforcement, or none for an intentional legacy opt-out."
  }
}

variable "enable_calico_network_policy" {
  description = "Removed input retained only as a migration guard; remove it and set network_policy_mode explicitly"
  type        = bool
  default     = null

  validation {
    condition     = var.enable_calico_network_policy == null
    error_message = "enable_calico_network_policy is no longer supported. Remove it and set network_policy_mode explicitly before planning or applying."
  }
}

variable "disable_calico_addon" {
  description = "Second-stage Calico opt-out: set true only with mode none after node enforcement has been disabled and the node rollout has completed"
  type        = bool
  default     = false
  nullable    = false
}

variable "node_count" {
  description = "Number of nodes in the node pool"
  type        = number
  default     = 1
}

variable "machine_type" {
  description = "Machine type for nodes"
  type        = string
  default     = "e2-standard-4"
}

variable "disk_size_gb" {
  description = "Disk size for nodes in GB"
  type        = number
  default     = 100
}

variable "use_spot_vms" {
  description = "Use Spot VMs for cost savings"
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels to apply to the cluster"
  type        = map(string)
  default     = {}
}

variable "network" {
  description = "VPC network name"
  type        = string
}

variable "subnetwork" {
  description = "VPC subnetwork name"
  type        = string
}

variable "pods_range_name" {
  description = "Name of the secondary range for pods"
  type        = string
  default     = "pods"
}

variable "services_range_name" {
  description = "Name of the secondary range for services"
  type        = string
  default     = "services"
}

variable "maintenance_recurring_window" {
  description = "Recurring GKE maintenance window (RFC3339 UTC start/end of the first occurrence plus an RFC5545 RRULE). Null leaves GKE free to upgrade at any time"
  type = object({
    start_time = string
    end_time   = string
    recurrence = string
  })
  default = null
}

variable "enable_deletion_protection" {
  description = "Enable deletion protection for the cluster (recommended for shared/production clusters)"
  type        = bool
  default     = false
}

variable "autoscaling" {
  description = "Node pool autoscaling limits. Null disables autoscaling and keeps node_count fixed"
  type = object({
    min_node_count = number
    max_node_count = number
  })
  default = null
}
