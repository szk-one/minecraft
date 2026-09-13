variable "project_id" {}
variable "region" {}
variable "zone" {}

variable "rcon_password" {
	description = "Minecraft サーバーへ固定で使用する RCON パスワード。空の場合は自動生成されます。"
	type        = string
	default     = ""
}

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

variable "metrics_scrape_interval" {
  description = "Ops Agent が Minecraft の Prometheus エンドポイントを取得する間隔。短くすると Cloud Monitoring の取り込み課金が増える。"
  type        = string
  default     = "60s"
}

variable "purge_legacy_monitoring_data" {
  description = "true にすると、旧 Prometheus / Grafana のデータディレクトリを起動スクリプトが削除してデータディスクを解放します。反映には VM の再起動が必要です。"
  type        = bool
  default     = false
}
