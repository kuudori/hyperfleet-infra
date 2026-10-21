terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "= 5.45.2"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "= 5.45.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "= 2.9.1"
    }
    oci = {
      source  = "oracle/oci"
      version = "= 7.32.0"
    }
  }
}
