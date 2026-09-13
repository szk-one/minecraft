output "mc_server_external_ip" {
  description = "Minecraft サーバーの外部 IP"
  value       = module.compute_engine.mc_server_external_ip
}

output "monitoring_dashboard_url" {
  description = "Cloud Monitoring の Minecraft Overview ダッシュボード URL"
  value       = module.compute_engine.monitoring_dashboard_url
}
