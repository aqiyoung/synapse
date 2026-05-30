# 知识库系统开发文档

> 最后更新：2026-05-30

## 核心理念

**全部交给 AI，零人工操作** — 后台脚本持续运行，自动完成标签、关联、质检等所有知识管理工作。

## 快速参考

- **前端文件**：`frontend/index.html`（单文件 SPA）
- **后端目录**：`backend/`
- **数据库**：`data/knowledge.db`
- **服务端口**：18800（Uvicorn）
- **Flutter 应用**：`app/`

## AI 自动化流程

```
用户写笔记 → AI 自动打标签 → AI 建立关联 → 后台质检 → 图谱更新
     ↓              ↓              ↓            ↓           ↓
   存入数据库    标签写入      wikilink生成   断链修复    力导向图
```

### 自动化功能

| 功能 | 触发方式 | 说明 |
|------|----------|------|
| 自动标签 | 笔记创建/更新时 | AI 分析内容语义，自动生成标签 |
| 自动关联 | 笔记创建/更新时 | AI 发现内容关联，自动建立 `[[wikilink]]` |
| 健康检查 | 定时任务 | 检测断链、孤立笔记、内容问题 |
| 图谱更新 | 实时 | 笔记变更时自动更新知识图谱 |

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

## 配置说明

### 环境变量

```bash
# 必填：LLM API 密钥
export LLM_API_KEY="your-api-key"

# 可选：LLM 配置
export LLM_BASE_URL="https://api.openai.com/v1"
export LLM_MODEL="gpt-4"

# 可选：API 认证
export WIKI_API_TOKEN="your-token"

# 可选：RAG 配置
export RAG_MAX_NOTES=5
export RAG_MAX_CHARS=8000
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

### AI 功能异常

```bash
# 检查 LLM API 连通性
curl -H "Authorization: Bearer $LLM_API_KEY" $LLM_BASE_URL/models

# 查看 AI 相关日志
grep -i "llm\|ai" logs/*.log
```

### Flutter 构建失败

```bash
cd app
flutter clean
flutter pub get
flutter build apk --release
```
