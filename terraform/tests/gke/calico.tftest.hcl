# Computed datapath values are only populated during mocked apply in Terraform
# 1.7-1.9. No real provider operations occur, and this file has isolated state.
mock_provider "google" {
  mock_resource "google_container_cluster" {
    defaults = {
      datapath_provider = "LEGACY_DATAPATH"
    }
  }
}

variables {
  project_id          = "test-project"
  cluster_name        = "calico-test"
  region              = "us-central1"
  zone                = "us-central1-a"
  network             = "test-network"
  subnetwork          = "test-subnetwork"
  network_policy_mode = "calico"
}

run "calico_legacy_cluster" {
  command = apply

  module {
    source = "./modules/cluster/gke"
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
