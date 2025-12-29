locals {
  services = toset([
    # https://registry.terraform.io/modules/terraform-google-modules/github-actions-runners/google/latest/submodules/gh-oidc#requirements
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    # iam
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    # Compute Engine
    "compute.googleapis.com",
    "logging.googleapis.com",
  ])
}

resource "google_project_service" "service" {
  for_each = local.services
  project = var.project_id
  service = each.value
  disable_on_destroy = false
  timeouts {
    create = "10m"
  }
}

resource "time_sleep" "wait_30_seconds" {
  create_duration = "30s"
  depends_on = [
    google_project_service.service,
  ]
}

data "google_project" "current" {
  project_id = var.project_id
}
