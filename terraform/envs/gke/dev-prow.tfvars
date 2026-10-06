# HyperFleet GKE Developer Environment - Long-running Reserved Cluster Used for Prow
#
# Usage:
#   terraform init -backend-config=envs/gke/dev-prow.tfbackend
#   terraform plan -var-file=envs/gke/dev-prow.tfvars
#   terraform apply -var-file=envs/gke/dev-prow.tfvars
#
# This file configures the prow cluster only. CI integration clusters render
# from ci.tfvars.template via `make ci-tf-env`, so settings here do not leak
# into CI.

# =============================================================================
# Required: Your Info
# =============================================================================
developer_name    = "prow"       # Your username (e.g., "your-username")
kubernetes_suffix = "hyperfleet" # Namespace suffix (allows multiple deployments to share a cluster)

# =============================================================================
# Environment (cicd = exempt from lifecycle enforcement)
# =============================================================================
environment = "cicd"

# =============================================================================
# Cloud Provider
# =============================================================================
cloud_provider = "gke"

# =============================================================================
# GCP Settings
# =============================================================================
gcp_project_id = "hcm-hyperfleet"
gcp_region     = "us-central1"
gcp_zone       = "us-central1-a"

# Network (created by shared infra - don't change unless you know what you're doing)
gcp_network    = "hyperfleet-dev-vpc"
gcp_subnetwork = "hyperfleet-dev-vpc-subnet"

# =============================================================================
# Cluster Configuration
# =============================================================================
node_count   = 1               # Start with 1 node for dev
machine_type = "e2-standard-4" # 4 vCPU, 16GB RAM
use_spot_vms = false           # ~70% cost savings, may be preempted

# Headroom for overlapping nightlies, idles back to 1 node
autoscaling = {
  min_node_count = 1
  max_node_count = 3
}

# Prow uses the legacy dataplane: Calico enables enforcement without replacing
# the cluster (nodes are recreated when enabling enforcement).
network_policy_mode = "calico"

# IMPORTANT: Enable deletion protection for this shared long-running cluster
# This prevents accidental deletion via terraform destroy
# To destroy, you must first set this to false, apply, then destroy
enable_deletion_protection = true

# Automatic GKE upgrades drain the node and restart Maestro, so keep them away
# from the nightlies (09:30, 11:30, 13:30 UTC daily) and weekday presubmits.
# Saturday and Sunday 18:00-06:00 UTC, 24h a week (GKE needs 48h in 32 days).
maintenance_recurring_window = {
  start_time = "2026-09-26T18:00:00Z"
  end_time   = "2026-09-27T06:00:00Z"
  recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
}

# =============================================================================
# Pub/Sub Configuration (for HyperFleet messaging)
# =============================================================================
use_pubsub         = false # Set to true to use Google Pub/Sub for event messaging
enable_dead_letter = false # Enable dead letter queue for failed messages

# Topic configurations - each topic can have different subscriptions and publishers
# Uncomment and customize as needed for your development environment
# pubsub_topic_configs = {
#   clusters = {
#     subscribers = {
#       adapter2 = {}
#       adapter1 = {}
#     }
#     publishers = {
#       sentinel = {}
#     }
#   }
#   nodepools = {
#     subscribers = {
#       adapter3 = {}
#     }
#     publishers = {
#       sentinel = {}
#     }
#   }
# }
