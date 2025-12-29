module "basic" {
  source = "../google/basic"
  project_id = var.project_id
}

module "compute_engine" {
  source = "../google/compute_engine"
  project_id = var.project_id
  region = var.region
  zone = var.zone
  depends_on = [ module.basic ]
}
