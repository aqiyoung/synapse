# 知识库系统开发文档

> 最后更新：2026-05-30

## 快速参考

- **前端文件**：`frontend/index.html`（单文件 SPA）
- **后端目录**：`backend/`
- **数据库**：`data/knowledge.db`
- **服务端口**：18800（Uvicorn）
- **Flutter 应用**：`app/`

## 修改代码后的操作

```bash
# 前端修改 → 直接生效（静态文件）
vim frontend/index.html

# 后端修改 → 重启服务
vim backend/api.py
# 如果使用 systemd：
sudo systemctl restart knowledge-base
# 或直接重启 Python 进程

# Nginx 修改 → 测试 + 重载
sudo nginx -t && sudo nginx -s reload
```

## 数据备份

```bash
# 备份数据库
cp data/knowledge.db data/knowledge.db.$(date +%Y%m%d)

# 完整备份
tar -czf backup_$(date +%Y%m%d).tar.gz data/ uploads/
```

## Flutter 开发

```bash
cd app

# 安装依赖
flutter pub get

# 运行调试
flutter run

# 构建 APK
flutter build apk --release

# 清理构建
flutter clean
```

## 后端开发

```bash
cd backend

# 安装依赖
pip install -r requirements.txt

# 运行测试
python -m pytest

# 代码格式化
black .
isort .
```

## 注意事项

- 前端 `index.html` 是单文件 SPA，所有 JS/CSS 都在这一个文件里
- 修改前会自动备份为 `index.html.bak.YYYYMMDD_HHMMSS`
- Vue 3 通过本地 `vue.global.prod.js` 加载，无需构建
- 知识图谱使用 Canvas 2D 渲染，力导向布局
- 支持深色/浅色主题切换（跟随系统或手动切换）
- Android 签名文件 `.jks` 不要提交到 Git

## 故障排查

### 服务无法启动

```bash
# 检查端口占用
lsof -i :18800

# 查看日志
journalctl -u knowledge-base -f
```

### 数据库问题

```bash
# 检查数据库
sqlite3 data/knowledge.db ".tables"

# 重建索引
sqlite3 data/knowledge.db "REINDEX;"
```

### Flutter 构建失败

```bash
# 清理并重新构建
cd app
flutter clean
flutter pub get
flutter build apk --release
```
