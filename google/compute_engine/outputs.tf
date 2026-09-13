output "mc_server_external_ip" {
  description = "Minecraft サーバーの外部 IP"
  value       = google_compute_instance.mc_server.network_interface[0].access_config[0].nat_ip
}

# Grafana (http://<IP>:3000) の代わりに参照するダッシュボード
output "monitoring_dashboard_url" {
  description = "Cloud Monitoring の Minecraft Overview ダッシュボード URL"
  value       = "https://console.cloud.google.com/monitoring/dashboards/builder/${basename(google_monitoring_dashboard.minecraft_overview.id)}?project=${var.project_id}"
}
