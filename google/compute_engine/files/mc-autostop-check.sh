#!/bin/bash
# minecraft-server コンテナが自分で終了していたら VM ごと停止する。
#
# itzg イメージの AUTOSTOP は「誰もいなくなったら Minecraft を止める」だけで、
# VM は起動したまま課金され続ける。コンテナの終了を検知して poweroff することで
# はじめてコスト削減になる。systemd timer から 1 分おきに呼ばれる。
set -uo pipefail

CONTAINER="minecraft-server"
# 起動直後の猶予 (秒)。前回 AUTOSTOP で終了したコンテナを docker compose が
# 起こし直す前に検知して、そのまま poweroff するループに入るのを防ぐ保険。
# AUTOSTOP_TIMEOUT_INIT は分単位なので、正常な停止がここに引っかかることはない。
MIN_UPTIME_SECONDS=180

uptime_seconds="$(cut -d. -f1 /proc/uptime)"
if [ "${uptime_seconds}" -lt "${MIN_UPTIME_SECONDS}" ]; then
  exit 0
fi

status="$(docker inspect -f '{{.State.Status}}' "${CONTAINER}" 2>/dev/null || true)"

# コンテナがまだ存在しない = 起動スクリプトの実行中。ここで止めると起動できなくなる。
if [ -z "${status}" ]; then
  exit 0
fi

case "${status}" in
  exited | dead)
    code="$(docker inspect -f '{{.State.ExitCode}}' "${CONTAINER}" 2>/dev/null || echo '?')"
    if [ "${code}" = "0" ]; then
      logger -t mc-autostop "minecraft-server が正常終了 (AUTOSTOP)。VM を停止します。"
    else
      # 異常終了でも VM は止める。起動しっぱなしの課金の方が痛いうえ、
      # サーバーログは Cloud Logging に残っているので後から追える。
      logger -t mc-autostop "minecraft-server が異常終了 (status=${status} exit_code=${code})。VM を停止します。Cloud Logging を確認してください。"
    fi
    # GCE では guest からの poweroff はインスタンスの TERMINATED (停止) になる。
    # ディスクは保持されるので、次回起動時にワールドはそのまま。
    #
    # --no-block は必須。systemd ユニットの中から待つ形で poweroff を投げると、
    # systemd が「この unit の停止」を待ち、unit は systemctl の完了を待つ、
    # というデッドロックになりうる。
    systemctl --no-block poweroff
    ;;
  *)
    exit 0
    ;;
esac
