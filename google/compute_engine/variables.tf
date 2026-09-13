variable "project_id" {}
variable "region" {}
variable "zone" {}

variable "machine_type" {
  description = "Minecraft サーバー VM のマシンタイプ。監視スタックを VM から降ろしたため、メモリを削ったタイプに落とせる。"
  type        = string
  default     = "n2-standard-4"
}

variable "mc_memory" {
  description = "Minecraft サーバーに割り当てる JVM ヒープ。machine_type のメモリより十分小さい値にすること。"
  type        = string
  default     = "10G"
}

variable "mc_allowed_source_ranges" {
  description = "CIDR ranges allowed to access Minecraft server"
  type = list(string)
  # 本番では自宅回線のIPだけに絞る
  default = ["0.0.0.0/0"]
}

variable "packwiz_url" {
  description = "公開された packwiz pack.toml の URL (例: GitHub Pages)"
  type        = string
  default = "https://szk-one.github.io/minecraft/pack.toml"
}

variable "rcon_password" {
  description = "Minecraft サーバーの RCON パスワード。空の場合は起動スクリプトで自動生成します。"
  type        = string
  default     = ""
}

variable "discord_webhook_url" {
  description = "サーバー起動通知を送信する Discord Webhook の URL"
  type        = string
  default     = ""
}

variable "metrics_scrape_interval" {
  description = "Ops Agent が Minecraft の Prometheus エンドポイントを取得する間隔。短くすると Cloud Monitoring の取り込み課金が増える。"
  type        = string
  default     = "60s"
}

variable "purge_legacy_monitoring_data" {
  description = "true にすると、旧 Prometheus / Grafana のデータディレクトリを起動スクリプトが削除してデータディスクを解放します。"
  type        = bool
  default     = false
}
