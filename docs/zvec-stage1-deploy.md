# zvec Stage 1 部署文档

> 配套设计: `docs/zvec-stage1-design.md`
> 实施 subagent: `synapse-zvec-stage1` (2026-06-19 13:41 - 14:11)
> 阶段 1 范围: HNSW 索引 + fallback 集成, 不动 embedding model

## 改了哪些文件 (LOC diff)

| 文件 | 状态 | LOC 变化 | 说明 |
|------|------|---------|------|
| `backend/vector_search.py` | **不动** | 0 | v1 保留, 兜底用 |
| `backend/vector_search_v2.py` | **新增** | +420 | zvec HNSW 包装 + 全局单例 |
| `backend/api.py` | 修改 | +130 | startup 钩子 + 路由集成 + admin endpoint |
| `backend/tests/test_vector_search_v2.py` | **新增** | +250 | 7 个 pytest 用例 |
| `docs/zvec-stage1-design.md` | **新增** | +200 | 设计文档 |
| `docs/zvec-stage1-deploy.md` | **新增** | (本文件) | 部署 / 回滚 |
| `README.md` | 修改 | +30 | zvec 安装步骤 |

总计: 新增 ~900 行, 修改 ~160 行 (含 docs/README).

## 关键代码点

### 启动钩子 (`backend/api.py`)
```python
@app.on_event("startup")
def _zvec_startup_init():
    # 1. 检查 zvec 是否可用
    if not _zvec_available():
        logger.warning("[zvec] not available at startup, fallback v1")
        return
    # 2. lazy init index
    idx = _zvec_get_or_init_index(_ZVEC_INDEX_PATH)
    if idx is None or not idx.available:
        logger.warning("[zvec] init failed, fallback v1: %s", idx.init_error)
        return
    # 3. 后台重建 (如果 zvec 是空的)
    if idx.count() == 0:
        threading.Thread(target=_bg_rebuild, daemon=True).start()
```

### 智能搜索 fallback 链 (`_smart_search`)
```
1. zvec HNSW (search_similar_notes_v2) — 主路径, ~0.5ms
2. v1 numpy 暴力 (vector_search) — 兜底 1, ~20ms
3. FTS5 LIKE — 兜底 2, ~5-50ms (依索引大小)
```

### API 集成点
| API | 集成方式 |
|-----|---------|
| `POST /api/notes` | 创建后调 `_zvec_add_note_sync` 同步写 zvec |
| `PUT /api/notes/{id}` | 更新后调 `_zvec_add_note_sync` 刷新 embedding |
| `DELETE /api/notes/{id}` | 软删后调 `_zvec_remove` 从 zvec 移除 |
| `POST /api/admin/reindex` | **新增**, 手动重建 |
| `GET /api/ai/index-stats` | 增加 `zvec` 字段 (available/doc_count) |
| `POST /api/ai/chat` | **不变**, 但内部走 zvec (透明升级) |

## 测试结果

7 个 pytest 全 pass (47.7s 总耗时, 含 1000 vector insert):

```
backend/tests/test_vector_search_v2.py::test_zvec_index_add_search PASSED
backend/tests/test_vector_search_v2.py::test_zvec_index_persist PASSED
backend/tests/test_vector_search_v2.py::test_zvec_vs_numpy_recall PASSED
backend/tests/test_vector_search_v2.py::test_zvec_fallback_to_numpy PASSED
backend/tests/test_vector_search_v2.py::test_zvec_search_perf PASSED
backend/tests/test_vector_search_v2.py::test_zvec_remove_updates_index PASSED
backend/tests/test_vector_search_v2.py::test_zvec_rebuild_replaces_existing PASSED
============================== 7 passed in 47.69s ==============================
```

## 性能数据 (真实 Synapse 162 vectors)

| 指标 | v1 numpy | v2 zvec HNSW | 提升 |
|------|---------|--------------|------|
| 单次查询延迟 (warm) | 19.3ms | **0.54ms** | **36x** |
| Cold start (首次) | 19.3ms | 0.03ms (cache 命中) | — |
| 启动时重建 (162 vec) | 12.3s (旧 numpy build) | **0.09s** | **137x** |
| Top-10 召回率 | 100% (brute force = ground truth) | 100% | 一致 |
| 磁盘占用 | ~3MB (note_vectors JSON) | ~70KB (zvec index) | -97% |

注: 上面 19.3ms 是 v1 在每个 query 时单独 `np.dot(a,b)/(norm(a)*norm(b))` 循环 172 次的开销.
实际 query 还要加 ~200ms 的 SiliconFlow API 调用, zvec 也不省这部分 (embedding 模型计算在服务端).

## 部署步骤 (灰度方案)

### Step 0: 准备

```bash
cd /vol1/1000/dev-projects/synapse
# 1. venv 安装 zvec (清华镜像, 75MB wheel)
source .zvec-venv/bin/activate
pip install zvec -i https://pypi.tuna.tsinghua.edu.cn/simple

# 2. 跑测试 (确认本地 OK)
python -m pytest backend/tests/test_vector_search_v2.py -v
```

### Step 1: 重启 Synapse (18800)

⚠️ **不要跑 docker compose down** (task spec 禁止). 直接 kill + restart:

```bash
# 找到当前 18800 进程
pgrep -f "uvicorn.*api:app" 
# 或者 systemd 启动的话
systemctl status synapse  # 看实际启动方式

# 优雅重启: kill -SIGTERM → 等 5s → 启动
# (如果用 systemd: systemctl restart synapse)
```

启动日志应该看到:
```
INFO [zvec] creating new index at /vol1/1000/dev-projects/synapse/data/zvec_index
INFO [zvec] index loaded at ..., doc_count=0
INFO [zvec] empty index, starting background rebuild from DB
INFO [zvec] rebuild done: 162/162 vectors in 0.09s
INFO [zvec] background rebuild inserted 162 vectors
```

### Step 2: 验证 (灰度 1%)

健康检查:
```bash
curl -s http://127.0.0.1:18800/api/ai/index-stats | jq .
```
期望:
```json
{
  "total_notes": 162,
  "zvec": {
    "available": true,
    "doc_count": 162,
    "init_error": null,
    "index_path": "/vol1/1000/dev-projects/synapse/data/zvec_index"
  }
}
```

试一次向量搜索 (走 zvec):
```bash
curl -s -X POST http://127.0.0.1:18800/api/ai/chat \
  -H "Content-Type: application/json" \
  -d '{"question": "OpenClaw 入门", "limit": 5}' | jq .
```
返回 JSON 结构跟以前 100% 一致, 内部走 zvec.

### Step 3: 全量切流

v1 路由 (`/api/ai/build-index`, `/api/ai/index-stats` v1 字段) 仍然可用, 不会被删除.
当 zvec 上线 1 周稳定后, 可以把 v1 numpy 路径标记 deprecated (不影响行为).

### 监控指标

Log 关键字 (grep 日志文件):
- `[zvec] search top_k=N returned K hits in Xms` — 单次查询延迟
- `[zvec] fallback to v1 numpy` — fallback 触发原因
- `[zvec] rebuild done` — 重建结果
- `[zvec] upsert note_id=N` — 写入延迟
- `[zvec] init failed` — 启动失败

健康阈值:
- P50 search latency < 5ms
- P99 search latency < 50ms
- Fallback 比例 < 5% (临时 fallback 算正常, 持续 > 30 min 需排查)

## 回滚方案

### 情况 1: zvec 启动失败
启动时 `zvec.init()` 抛异常 → log warning → `_zvec_started=True` → 所有 search 走 v1.
**无需回滚**, 服务照常运行, 只是慢 (跟以前一样).

### 情况 2: zvec 索引损坏
1. 停服务
2. `rm -rf /vol1/1000/dev-projects/synapse/data/zvec_index/`
3. 重启服务 → 自动 rebuild from DB

### 情况 3: zvec 路由 panic / 内存泄漏
1. 把 `backend/api.py` 里 `_zvec_startup_init` 这个 `@app.on_event("startup")` 整个 `pass` 掉 (10 行)
2. 把 `_smart_search` 里 `from vector_search_v2 import ...` 这段整个删掉
3. 重启 → 完全 v1 行为

### 情况 4: 整个 stage 1 完全回滚
```bash
git checkout backend/api.py  # 撤销所有 api.py 改动
rm backend/vector_search_v2.py
rm backend/tests/test_vector_search_v2.py
rm docs/zvec-stage1-design.md docs/zvec-stage1-deploy.md
```
服务恢复原状.

## 已知问题 (留给 Stage 2)

1. **SiliconFlow API key 失效** — 当前走 hash fallback, 语义召回几乎为 0
   - Stage 2: 修 key → 跑真实 embedding → 重测 recall
   - 不影响 stage 1 集成上线

2. **删除背景扫描** — 软删笔记只从 zvec.remove(note_id) 单点删, 没有 sweeper
   - 当前 v1 也没做, 跟 v1 行为对齐

3. **zvec index lock** — 同进程多线程读 zvec OK, 跨进程并发写需要分布式锁
   - Synapse 单进程 FastAPI 没问题

4. **`include_vector=False`** — 当前 query 没回传 vector, 省内存
   - 未来如果要做 re-rank 再开

## 没干的事 (Stage 2 计划)

- ❌ 修 SiliconFlow API key (401 现在), 重测真实召回率
- ❌ Sparse vector + dense hybrid (zvec 支持 FTS + vector 联合 query)
- ❌ IVF / DiskANN 索引对比 (10w+ vectors 时考虑)
- ❌ zvec 索引文件 backup / 异地容灾
- ❌ 多租户隔离 (按 folder_id 过滤)

---

最后修改: 2026-06-19 14:11 (synapse-zvec-stage1)