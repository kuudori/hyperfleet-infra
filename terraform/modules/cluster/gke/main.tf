resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone
  project  = var.project_id

  # Network configuration
  network    = var.network
  subnetwork = var.subnetwork

  # Use VPC-native cluster with secondary ranges
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Dataplane V2 is immutable. Leave this unset for legacy clusters so enabling
  # Calico updates them in place instead of forcing a cluster replacement.
  datapath_provider = var.network_policy_mode == "dataplane_v2" ? "ADVANCED_DATAPATH" : null

  dynamic "network_policy" {
    for_each = var.network_policy_mode == "calico" ? [1] : []
    content {
      enabled  = true
      provider = "CALICO"
    }
  }

  addons_config {
    network_policy_config {
      # Dataplane V2 enforces policies natively; it must not use the Calico addon.
      disabled = var.network_policy_mode != "calico"
    }
  }

  # Recurring maintenance window for automatic upgrades (times in UTC).
  # Without one, GKE upgrades at any time and drains nodes mid test run.
  dynamic "maintenance_policy" {
    for_each = var.maintenance_recurring_window == null ? [] : [var.maintenance_recurring_window]
    content {
      recurring_window {
        start_time = maintenance_policy.value.start_time
        end_time   = maintenance_policy.value.end_time
        recurrence = maintenance_policy.value.recurrence
      }
    }
  }

  # We manage the node pool separately
  remove_default_node_pool = true
  initial_node_count       = 1

  # Enable Workload Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  resource_labels = var.labels

  # Deletion protection - enable for shared/production clusters
  # When enabled, prevents deletion via GCP Console, API, and Terraform
  # Must be set to false before cluster can be destroyed
  deletion_protection = var.enable_deletion_protection
}

resource "google_container_node_pool" "primary" {
  name     = "${var.cluster_name}-pool"
  location = var.zone
  cluster  = google_container_cluster.primary.name
  project  = var.project_id

  # Unset when autoscaling is on, so Terraform doesn't fight the autoscaler on every apply
  node_count = var.autoscaling == null ? var.node_count : null

  dynamic "autoscaling" {
    for_each = var.autoscaling == null ? [] : [var.autoscaling]
    content {
      min_node_count = autoscaling.value.min_node_count
      max_node_count = autoscaling.value.max_node_count
    }
  }

  node_config {
    machine_type    = var.machine_type
    disk_size_gb    = var.disk_size_gb
    spot            = var.use_spot_vms
    resource_labels = var.labels

    # Network tags for firewall rules (e.g., LoadBalancer health checks)
    tags = ["gke-${var.cluster_name}"]

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = var.labels
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
