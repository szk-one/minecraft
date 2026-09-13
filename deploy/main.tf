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
  machine_type = var.machine_type
  mc_memory = var.mc_memory
  metrics_scrape_interval = var.metrics_scrape_interval
  purge_legacy_monitoring_data = var.purge_legacy_monitoring_data
  depends_on = [ module.basic ]
}
