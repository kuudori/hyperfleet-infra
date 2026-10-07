mock_provider "google" {
  mock_resource "google_container_cluster" {
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

run "reject_module_legacy_datapath" {
  command = plan

  module {
    source = "./modules/cluster/gke"
  }

  variables {
    datapath_provider = ""
  }

  expect_failures = [var.datapath_provider]
}

run "reject_module_legacy_calico_flag" {
  command = plan

  module {
    source = "./modules/cluster/gke"
  }

  variables {
    enable_calico_network_policy = true
  }

  expect_failures = [var.enable_calico_network_policy]
}

run "reject_addon_disable_with_dataplane_v2" {
  command = plan

  module {
    source = "./modules/cluster/gke"
  }

  variables {
    disable_calico_addon = true
  }

  expect_failures = [google_container_cluster.primary]
}

run "reject_addon_disable_with_calico" {
  command = plan

  module {
    source = "./modules/cluster/gke"
  }

  variables {
    network_policy_mode  = "calico"
    disable_calico_addon = true
  }

  expect_failures = [google_container_cluster.primary]
}
