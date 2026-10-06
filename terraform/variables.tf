# =============================================================================
# Cloud Provider Selection
# =============================================================================
variable "cloud_provider" {
  description = "Cloud provider to use: gke, eks, aks"
  type        = string
  default     = "gke"

  validation {
    condition     = contains(["gke", "eks", "aks"], var.cloud_provider)
    error_message = "cloud_provider must be one of: gke, eks, aks"
  }
}

# =============================================================================
# Common Variables
# =============================================================================
variable "developer_name" {
  description = "Developer's username (used in cluster naming)"
  type        = string
}

variable "kubernetes_suffix" {
  description = "Suffix for Kubernetes namespace (allows multiple deployments to share a cluster)"
  type        = string
  default     = "default"
}

variable "environment" {
  description = "Environment label for the cluster (dev, cicd). Clusters with 'cicd' are exempt from lifecycle enforcement."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "cicd"], var.environment)
    error_message = "environment must be one of: dev, cicd"
  }
}

# =============================================================================
# Cluster Configuration
# =============================================================================
variable "node_count" {
  description = "Number of nodes in the cluster"
  type        = number
  default     = 1
}

variable "machine_type" {
  description = "Machine/instance type"
  type        = string
  default     = "e2-standard-4"
}

variable "use_spot_vms" {
  description = "Use Spot/Preemptible VMs for cost savings"
  type        = bool
  default     = true
}

variable "maintenance_recurring_window" {
  description = "Recurring GKE maintenance window (RFC3339 UTC start/end of the first occurrence plus an RFC5545 RRULE). Null leaves GKE free to upgrade at any time, set it for shared clusters like Prow"
  type = object({
    start_time = string
    end_time   = string
    recurrence = string
  })
  default = null
}

variable "autoscaling" {
  description = "Node pool autoscaling limits. Null disables autoscaling and keeps node_count fixed"
  type = object({
    min_node_count = number
    max_node_count = number
  })
  default = null
}

variable "enable_deletion_protection" {
  description = "Enable deletion protection for the cluster (recommended for shared/production clusters like Prow)"
  type        = bool
  default     = false
}

# =============================================================================
# GCP-Specific Variables
# =============================================================================
variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
  default     = "hcm-hyperfleet"
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "gcp_zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"
}

variable "network_policy_mode" {
  description = "GKE NetworkPolicy enforcement: dataplane_v2 for new clusters, calico for existing legacy clusters, or none to explicitly disable enforcement"
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

variable "gcp_network" {
  description = "VPC network name (created by shared infra)"
  type        = string
  default     = "hyperfleet-dev-vpc"
}

variable "gcp_subnetwork" {
  description = "VPC subnetwork name (created by shared infra)"
  type        = string
  default     = "hyperfleet-dev-vpc-subnet"
}

# =============================================================================
# AWS-Specific Variables (future)
# =============================================================================
variable "aws_region" {
  description = "AWS region (for future EKS support)"
  type        = string
  default     = "us-east-1"
}

# =============================================================================
# Pub/Sub Configuration
# =============================================================================

variable "use_pubsub" {
  description = "Use Google Pub/Sub for HyperFleet messaging (instead of RabbitMQ)"
  type        = bool
  default     = false
}

variable "enable_dead_letter" {
  description = "Enable dead letter queue for Pub/Sub"
  type        = bool
  default     = true
}

variable "pubsub_topic_configs" {
  description = <<-EOT
    Pub/Sub topic configurations. Each topic can have its own set of subscriptions and publishers.

    Example:
      pubsub_topic_configs = {
        clusters = {
          subscribers = {
            adapter1 = { ack_deadline_seconds = 120 }
            adapter2 = {}
          }
          publishers = {
            sentinel = {}
          }
        }
        nodepools = {
          subscribers = {
            adapter3 = {}
          }
          publishers = {
            sentinel = {}
          }
        }
      }
  EOT
  type = map(object({
    message_retention_duration = optional(string, "604800s")
    subscribers = optional(map(object({
      ack_deadline_seconds = optional(number, 60)
      roles                = optional(list(string), ["roles/pubsub.subscriber", "roles/pubsub.viewer"])
    })), {})
    publishers = optional(map(object({
      roles = optional(list(string), ["roles/pubsub.publisher", "roles/pubsub.viewer"])
    })), {})
  }))
  default = {
    clusters = {
      subscribers = {
        adapter1 = {}
        adapter2 = {}
      }
      publishers = {
        sentinel = {}
      }
    }
    nodepools = {
      subscribers = {
        adapter3 = {}
      }
      publishers = {
        sentinel = {}
      }
    }
  }
}

# =============================================================================
# External Gateway Access
# =============================================================================
variable "enable_external_gateway" {
  description = "Enable external access to HyperFleet Gateway via LoadBalancer service"
  type        = bool
  default     = false
}
