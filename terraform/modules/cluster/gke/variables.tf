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

variable "datapath_provider" {
  description = "GKE datapath provider. Immutable after creation, changing it recreates the cluster. Empty string keeps the GKE default (legacy) datapath"
  type        = string
  default     = "ADVANCED_DATAPATH"
}

variable "enable_calico_network_policy" {
  description = "Enable Calico NetworkPolicy enforcement. Only for clusters on the legacy datapath (datapath_provider = \"\"), Dataplane V2 enforces NetworkPolicy natively"
  type        = bool
  default     = false
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
