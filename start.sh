#!/bin/bash
# 知识库启动脚本

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR/backend"

# 检查依赖
pip show fastapi uvicorn sqlalchemy 2>/dev/null | head -1 || {
    echo "安装依赖..."
    pip install fastapi uvicorn sqlalchemy python-multipart --break-system-packages 2>&1 | tail -3
}

# 启动后端
echo "启动知识库服务..."
python3 -m uvicorn main:app --host 0.0.0.0 --port 18800 --reload &
BACKEND_PID=$!

# 等待后端启动
sleep 2

echo ""
echo "========================================="
echo "  知识库已启动！"
echo "  访问地址: http://localhost:18800"
echo "  后端 API: http://localhost:18800/api"
echo "  按 Ctrl+C 停止"
echo "========================================="
echo ""

# 等待中断
trap "kill $BACKEND_PID 2>/dev/null; echo '已停止'; exit 0" INT TERM
wait
