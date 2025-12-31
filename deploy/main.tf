module "basic" {
  source = "../google/basic"
  project_id = var.project_id
}

module "compute_engine" {
  source = "../google/compute_engine"
  project_id = var.project_id
  region = var.region
  zone = var.zone
  rcon_password = var.rcon_password
  depends_on = [ module.basic ]
}
