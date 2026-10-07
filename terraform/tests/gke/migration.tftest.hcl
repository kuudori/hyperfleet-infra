mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "local" {}

variables {
  developer_name = "migration-test"
}

run "reject_root_legacy_datapath" {
  command = plan

  variables {
    datapath_provider = ""
  }

  expect_failures = [var.datapath_provider]
}

run "reject_root_legacy_calico_flag" {
  command = plan

  variables {
    enable_calico_network_policy = true
  }

  expect_failures = [var.enable_calico_network_policy]
}

run "reject_root_legacy_dataplane_v2" {
  command = plan

  variables {
    datapath_provider = "ADVANCED_DATAPATH"
  }

  expect_failures = [var.datapath_provider]
}

run "reject_root_enforcement_opt_out" {
  command = plan

  variables {
    network_policy_mode = "none"
  }

  expect_failures = [var.network_policy_mode]
}

run "reject_root_addon_opt_out" {
  command = plan

  variables {
    disable_calico_addon = true
  }

  expect_failures = [var.disable_calico_addon]
}
