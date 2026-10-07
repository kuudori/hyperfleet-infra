mock_provider "google" {
  mock_resource "google_container_cluster" {
    defaults = {
      datapath_provider = "LEGACY_DATAPATH"
    }
  }
}

variables {
  project_id          = "test-project"
  cluster_name        = "none-test"
  region              = "us-central1"
  zone                = "us-central1-a"
  network             = "test-network"
  subnetwork          = "test-subnetwork"
  network_policy_mode = "none"
}

run "calico_before_opt_out" {
  command = apply

  module {
    source = "./modules/cluster/gke"
  }

  variables {
    network_policy_mode = "calico"
  }

  assert {
    condition     = google_container_cluster.primary.network_policy[0].enabled && !google_container_cluster.primary.addons_config[0].network_policy_config[0].disabled
    error_message = "The starting Calico state must enable node enforcement and the addon."
  }
}

run "disable_node_enforcement_first" {
  command = apply

  module {
    source = "./modules/cluster/gke"
  }

  assert {
    condition     = google_container_cluster.primary.datapath_provider == "LEGACY_DATAPATH"
    error_message = "Opting out must leave the legacy datapath unchanged."
  }

  assert {
    condition     = !google_container_cluster.primary.network_policy[0].enabled && !google_container_cluster.primary.addons_config[0].network_policy_config[0].disabled
    error_message = "The first opt-out stage must disable node enforcement while leaving the addon enabled."
  }
}

run "disable_addon_after_node_rollout" {
  command = apply

  module {
    source = "./modules/cluster/gke"
  }

  variables {
    disable_calico_addon = true
  }

  assert {
    condition     = !google_container_cluster.primary.network_policy[0].enabled && google_container_cluster.primary.addons_config[0].network_policy_config[0].disabled
    error_message = "The second opt-out stage must keep node enforcement off and disable the addon."
  }
}
