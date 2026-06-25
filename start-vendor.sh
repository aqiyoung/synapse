#!/bin/bash
# vendor 启动 Synapse (zvec 在项目 vendor/)
# 抢占 18800 端口 — OpenClaw 守护会拉起 root 进程,  我们抢时间占端口
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR/backend"
export PYTHONPATH="$DIR/vendor:$DIR/vendor/zvec:${PYTHONPATH:-}"

# 杀 root spawn
for i in 1 2 3 4 5; do
    pid=$(lsof -ti:18800 2>/dev/null)
    if [ -n "$pid" ]; then
        sudo kill -KILL $pid 2>/dev/null || kill -KILL $pid 2>/dev/null
    fi
    sleep 0.3
done

# 立刻 spawn
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 18800 > "$DIR/logs/synapse-vendor.log" 2>&1 &
echo "Synapse vendor PID: $!"
sleep 2
# 验证 zvec
curl -sS -m 5 "http://127.0.0.1:18800/api/ai/index-stats" 2>&1
echo
# 触发 rebuild
curl -sS -X POST -m 30 "http://127.0.0.1:18800/api/admin/reindex" 2>&1
