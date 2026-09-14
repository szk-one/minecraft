output "mc_server_external_ip" {
  description = "Minecraft サーバーの外部 IP"
  value       = module.compute_engine.mc_server_external_ip
}

output "monitoring_dashboard_url" {
  description = "Cloud Monitoring の Minecraft Overview ダッシュボード URL"
  value       = module.compute_engine.monitoring_dashboard_url
}

output "minecraft_connect_address" {
  description = "プレイヤーに案内する接続先。wake proxy を使う場合はこれが固定の窓口になる。"
  value       = module.compute_engine.minecraft_connect_address
}

output "wake_proxy_external_ip" {
  description = "待ち受けプロキシの外部 IP。enable_wake_proxy = false のときは null。"
  value       = module.compute_engine.wake_proxy_external_ip
}
