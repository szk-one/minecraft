output "mc_server_external_ip" {
  description = "Minecraft サーバーの外部 IP"
  value       = google_compute_instance.mc_server.network_interface[0].access_config[0].nat_ip
}

# Grafana (http://<IP>:3000) の代わりに参照するダッシュボード
output "monitoring_dashboard_url" {
  description = "Cloud Monitoring の Minecraft Overview ダッシュボード URL"
  value       = "https://console.cloud.google.com/monitoring/dashboards/builder/${basename(google_monitoring_dashboard.minecraft_overview.id)}?project=${var.project_id}"
}

output "minecraft_connect_address" {
  description = "プレイヤーに案内する接続先。wake proxy がある場合はその固定 IP になる。"
  value       = local.connect_address != "" ? local.connect_address : "${google_compute_instance.mc_server.network_interface[0].access_config[0].nat_ip}:25565"
}

output "wake_proxy_external_ip" {
  description = "待ち受けプロキシの外部 IP。enable_wake_proxy = false のときは null。"
  value       = local.wake_proxy_ip
}
