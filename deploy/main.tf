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
  discord_webhook_url = var.discord_webhook_url
  enable_autostop = var.enable_autostop
  autostop_timeout_est = var.autostop_timeout_est
  autostop_timeout_init = var.autostop_timeout_init
  backup_interval = var.backup_interval
  prune_backups_days = var.prune_backups_days
  enable_wake_proxy = var.enable_wake_proxy
  wake_proxy_machine_type = var.wake_proxy_machine_type
  wake_proxy_start_cooldown = var.wake_proxy_start_cooldown
  wake_proxy_install_ops_agent = var.wake_proxy_install_ops_agent
  depends_on = [ module.basic ]
}
