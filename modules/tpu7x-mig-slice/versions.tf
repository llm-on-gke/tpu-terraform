terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      # target_size_policy (BULK) on MIGs was added in v7.28.0; verified against v8.7.0.
      version = ">= 7.28.0, < 9.0.0"
    }
  }
}
