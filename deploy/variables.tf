variable "project_id" {}
variable "region" {}
variable "zone" {}

variable "rcon_password" {
	description = "Minecraft サーバーへ固定で使用する RCON パスワード。空の場合は自動生成されます。"
	type        = string
	default     = ""
}
