mock_provider "google" {
  mock_resource "google_container_cluster" {
    override_during = plan
    defaults = {
      # Model the API's computed default when the immutable field is omitted.
      datapath_provider = "LEGACY_DATAPATH"
    }
  }
}

variables {
  project_id   = "test-project"
  cluster_name = "network-policy-test"
  region       = "us-central1"
  zone         = "us-central1-a"
  network      = "test-network"
  subnetwork   = "test-subnetwork"
}

run "default_dataplane_v2" {
  command = plan

  module {
    source = "./modules/cluster/gke"
  }

  assert {
    condition     = google_container_cluster.primary.datapath_provider == "ADVANCED_DATAPATH"
    error_message = "New clusters must default to Dataplane V2."
  }

  assert {
    condition     = length(google_container_cluster.primary.network_policy) == 0 && google_container_cluster.primary.addons_config[0].network_policy_config[0].disabled
    error_message = "Dataplane V2 must not enable the Calico addon or network_policy block."
  }
}

run "calico_legacy_cluster" {
  command = plan

  module {
    source = "./modules/cluster/gke"
  }

  variables {
    network_policy_mode = "calico"
  }

  assert {
    condition     = google_container_cluster.primary.datapath_provider == "LEGACY_DATAPATH"
    error_message = "Calico must leave the immutable datapath_provider unset to avoid replacing legacy clusters."
  }

  assert {
    condition     = google_container_cluster.primary.network_policy[0].enabled && google_container_cluster.primary.network_policy[0].provider == "CALICO"
    error_message = "Calico must enable NetworkPolicy enforcement with the CALICO provider."
  }

  assert {
    condition     = !google_container_cluster.primary.addons_config[0].network_policy_config[0].disabled
    error_message = "Calico requires the NetworkPolicy addon to be enabled."
  }
}

run "explicit_none" {
  command = plan

  module {
    source = "./modules/cluster/gke"
  }

  variables {
    network_policy_mode = "none"
  }

  assert {
    condition     = google_container_cluster.primary.datapath_provider == "LEGACY_DATAPATH" && length(google_container_cluster.primary.network_policy) == 0 && google_container_cluster.primary.addons_config[0].network_policy_config[0].disabled
    error_message = "Only an explicit none selection may disable both enforcement engines."
  }
}

run "reject_unknown_mode" {
  command = plan

  module {
    source = "./modules/cluster/gke"
  }

  variables {
    network_policy_mode = "typo"
  }

  expect_failures = [var.network_policy_mode]
}

run "null_keeps_safe_default" {
  command = plan

  module {
    source = "./modules/cluster/gke"
  }

  variables {
    network_policy_mode = null
  }

  assert {
    condition     = google_container_cluster.primary.datapath_provider == "ADVANCED_DATAPATH"
    error_message = "A null input must use the safe Dataplane V2 default, not disable enforcement."
  }
}
