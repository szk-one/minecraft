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

variable "discord_webhook_url" {
  description = "サーバー起動通知を送る Discord Webhook の URL。空なら通知しない。アイドル自動停止を入れると起動のたびに通知が飛ぶ。"
  type        = string
  default     = ""
}

variable "enable_autostop" {
  description = "誰も接続していないときに Minecraft を終了し、VM ごと停止するか。コスト削減の主役。"
  type        = bool
  default     = true
}

variable "autostop_timeout_est" {
  description = "最後のプレイヤーが退出してからサーバーを終了するまでの秒数。"
  type        = number
  default     = 1200
}

variable "autostop_timeout_init" {
  description = "サーバー起動後、誰も接続しないまま終了するまでの秒数。"
  type        = number
  default     = 900
}

variable "backup_interval" {
  description = "mc-backup のバックアップ間隔。稼働時間が短くなるため既定の 24h から縮めている。"
  type        = string
  default     = "2h"
}

variable "prune_backups_days" {
  description = "バックアップを保持する日数。"
  type        = number
  default     = 7
}

variable "enable_wake_proxy" {
  description = "常時稼働の待ち受けプロキシ VM を建てるか。プレイヤーはこのプロキシに接続し、参加操作で Minecraft VM が起動する。"
  type        = bool
  default     = true
}

variable "wake_proxy_machine_type" {
  description = "待ち受けプロキシのマシンタイプ。既定の e2-micro は無料枠の対象。"
  type        = string
  default     = "e2-micro"
}

variable "wake_proxy_start_cooldown" {
  description = "待ち受けプロキシが VM 起動を要求してから、次の起動要求を受け付けるまでの秒数。"
  type        = number
  default     = 120
}

variable "wake_proxy_install_ops_agent" {
  description = "待ち受けプロキシに Ops Agent を入れて起動要求のログを Cloud Logging に送るか。"
  type        = bool
  default     = true
}
