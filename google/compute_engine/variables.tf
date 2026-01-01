variable "project_id" {}
variable "region" {}
variable "zone" {}

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

variable "monitoring_allowed_source_ranges" {
  description = "Prometheus/Grafana のアクセスを許可する CIDR 範囲"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "grafana_admin_password" {
  description = "Grafana の管理者パスワード。空の場合は起動スクリプトで自動生成します。"
  type        = string
  default     = ""
}
