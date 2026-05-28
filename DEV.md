# 知识库系统开发文档（DEV）

> 最后更新：2026-05-28

## 快速参考

- **前端文件**：`frontend/index.html`
- **后端目录**：`backend/`
- **数据库**：`data/knowledge.db`
- **服务端口**：18800（Uvicorn）
- **服务管理**：`sudo systemctl restart knowledge-base`

## 修改代码后的操作

```bash
# 前端修改 → 直接生效（静态文件）
vim frontend/index.html

# 后端修改 → 重启服务
vim backend/api.py
sudo systemctl restart knowledge-base

# Nginx 修改 → 测试 + 重载
sudo nginx -t && sudo nginx -s reload
```

## 数据备份

```bash
cp data/knowledge.db data/knowledge.db.$(date +%Y%m%d)
```

## 注意事项

- 前端 index.html 是单文件 SPA，所有 JS/CSS 都在这一个文件里
- 修改前会自动备份为 `index.html.bak.YYYYMMDD_HHMMSS`
- Vue 3 通过 CDN 加载（vue.global.prod.js），无需构建
- 知识图谱使用 Canvas 2D 渲染，力导向布局
- 支持深色/浅色主题切换（跟随系统或手动切换）
