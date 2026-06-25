# zvec Stage 1 设计文档

> 状态: **实施中** (2026-06-19 阶段 1)
> 老板 13:36 拍板启动 → subagent `synapse-zvec-stage1` 落地
> 上游调研: `docs/zvec-integration-proposal.md` (6/19 37 min 跑完, prototype 1万篇 HNSW 112x)

## 目标

把 Synapse 知识库的向量检索从 **numpy 暴力扫描** 升级到 **zvec 0.5.0 HNSW**。

- 现状: `backend/vector_search.py` 用 SiliconFlow Qwen3-Embedding-0.6B (1024 dim) + numpy 余弦相似度, 172/235 篇已索引, 1 篇 query 扫 172 次 dot product
- 目标: HNSW (M=16, ef_construction=200, ef_search=50), 同样的 embedding API + DB, search 提速 100x

## 设计原则 (5 条铁律)

1. **不删 v1 代码** — `vector_search.py` 保留, 新增 `vector_search_v2.py` 并存
2. **不碰生产 data/** — zvec 索引路径 `/vol1/1000/dev-projects/synapse/data/zvec_index/`, 如有旧 `.idx` 先 `.bak`
3. **不开新端口** — 还是 18800
4. **不破坏现有 API 行为** — `/api/ai/chat` 返回 JSON 结构 100% 一致, 内部走 zvec
5. **不换 embedding model** — Qwen3-Embedding-0.6B, dim=1024

## HNSW 参数选择

| 参数 | 取值 | 依据 |
|------|------|------|
| `M` | 16 | prototype 验证, 召回 +51.8pp, 内存可控 (172 篇 ≈ 几 MB) |
| `ef_construction` | 200 | prototype, 平衡构建时间 + 图质量 |
| `ef_search` | 50 | 默认足够, 实测 100.6ms → 0.9ms, top-10 召回 > 95% |
| `metric_type` | `COSINE` | 跟 v1 numpy 余弦保持一致, 不引入 IP 误差 |
| `quantize_type` | `UNDEFINED` | 1024 dim × FP32 = 4KB/vector, 172 篇 = 0.7MB, 不需要 INT8 压缩 |

## 数据流

```
启动
  │
  ├─ /data/zvec_index/ 存在? → load (open)
  │                      否 → create_and_open with HNSW schema, 后台 rebuild from DB
  │
  ├─ 后台 task rebuild_index_from_db():
  │    - 读 notes (WHERE deleted_at IS NULL)
  │    - 读 note_vectors (已有 embedding)
  │    - 批量 insert 到 zvec collection
  │    - 失败一条 → log warning, 不中断重建
  │
写笔记 / 更新笔记
  │
  ├─ api_create_note → create_note (DB)
  ├─ 后台 task (新增) get_embedding() → zvec.upsert(id, vec)
  │    - embedding API 失败 → 用 hash fallback (跟 prototype 一致), 打 warning
  │    - zvec 写入失败 → log error, 不影响 DB 写入
  │
搜索 (/api/ai/chat → _smart_search)
  │
  ├─ zvec collection 已加载? → 用 zvec.search(queries, topk=N)
  │                            返回 [(note_id, score), ...]
  ├─ zvec 不可用 / 异常? → fallback 到 v1.vector_search (numpy)
  │
删笔记 (软删 → DB deleted_at IS NOT NULL)
  │
  ├─ 当前: 不主动从 zvec 移除 (跟 v1 一致, 已索引但查不到)
  └─ Stage 2: 加 zvec.delete_by_filter("deleted_at != null")
```

## API 与集成点

| 文件 | 改动 |
|------|------|
| `backend/vector_search.py` | **不动**, 保留所有 v1 函数 |
| `backend/vector_search_v2.py` | **新增**: `ZvecIndex` class + helpers |
| `backend/api.py` | 改 4 处: ① `@app.on_event("startup")` 懒加载; ② `_smart_search` 优先 v2; ③ `api_create_note` 后台 v2.upsert; ④ 新增 `/api/admin/reindex` |
| `backend/main.py` | **不动** (跟 v1 一样 import api) |

## ZvecIndex 类 API

```python
class ZvecIndex:
    def __init__(self, path: str, dim: int = 1024): ...
    def add(self, note_id: int, embedding: List[float], title: str = "") -> bool: ...
    def remove(self, note_id: int) -> bool: ...
    def search(self, query_vec: List[float], top_k: int = 10) -> List[Tuple[int, float]]: ...
    def rebuild(self, docs: List[Tuple[int, List[float], str]]) -> int: ...
    def count(self) -> int: ...
    @property
    def available(self) -> bool: ...  # False → fallback v1
```

全局单例: `get_or_init_index() -> ZvecIndex` (首次调用 lazy init)

## 兼容 / 回退策略

| 场景 | 行为 |
|------|------|
| zvec wheel 未装 | `ZvecIndex` init 抛 ImportError → log warning → `_smart_search` 走 v1 |
| zvec 索引文件损坏 | 启动时 backup + rebuild from DB |
| `get_embedding` SiliconFlow key 失效 | 用 hash fallback (1024 dim, 跟真实 embedding 维度一致) + warning log |
| zvec query 抛 RuntimeError | 自动 fallback v1, 记 error, 5xx 不抛 |
| 测试环境无 SiliconFlow | hash fallback OK, 不影响 zvec 性能/召回测试 |

## 持久化

- 路径: `/vol1/1000/dev-projects/synapse/data/zvec_index/`
- 备份: 启动时检测到旧索引, 先 `mv .bak.<ts>` 再 load
- `gitignore` 已有 `data/` 排除规则, 索引不进版本控制
- 注: zvec Collection 自身支持 `flush()` 落盘, 每次 upsert 后调一次 (低频写, 172 篇规模)

## 监控指标

新增 timing log:
```
[zvec] search 5 hits in 0.83ms (top score=0.92) qvec_dim=1024
[zvec] rebuild done: 162/172 vectors in 12.3s
[zvec] fallback to v1 numpy: <reason>
[zvec] upsert note 42 in 4.1ms
```

业务侧: `_smart_search` 已有的 `logger.info(f"向量搜索成功: {len(ids)} 个结果")` 保留, 内部走 zvec 还是 numpy 透明。

## 测试覆盖 (`backend/tests/test_vector_search_v2.py`)

| Test | 验证 |
|------|------|
| `test_zvec_index_add_search` | 加 5 个 vector, 搜最近邻, top-1 是自己 |
| `test_zvec_index_persist` | 写完持久化, 重启 load, 数据没丢 |
| `test_zvec_vs_numpy_recall` | 50 个随机 vector, zvec top-10 vs numpy brute top-10, 召回率 > 90% |
| `test_zvec_fallback_to_numpy` | mock zvec 抛异常, 验证 fallback 走 v1 |
| `test_zvec_search_perf` | 1000 vector, zvec search < 5ms |

## Stage 1 不做的事 (留给 Stage 2)

- ❌ 修 SiliconFlow key, 用真实 Qwen3-Embedding 跑真实召回率 (现在 key 失效, 用 hash fallback)
- ❌ 删除时 `delete_by_filter("deleted_at != null")` (跟 v1 行为对齐)
- ❌ 重新索引 admin endpoint 加 API token 鉴权 (现在依赖现有 ADMIN_PASSWORD)
- ❌ 软删笔记从 zvec 移除的 background sweeper
- ❌ 多模态 / sparse vector / IVF / DiskANN 等其他索引

## 风险与回滚

| 风险 | 触发 | 回滚 |
|------|------|------|
| zvec wheel 在 NAS 上挂掉 | startup 时 `zvec.init()` 失败 | 代码 fallback, 行为 = v1 |
| zvec 索引文件被污染 | rebuild 异常后 `.bak` 失败 | 手动删 `data/zvec_index/`, 重启 auto-rebuild |
| hash fallback 导致召回差 | 真实 query 没匹配 | Stage 2 修 SiliconFlow key 后重测 |
| API 行为变了 | response 字段不一致 | v1.vector_search 函数原封保留, 改 `_smart_search` 一行 import |

---

最后修改: 2026-06-19 13:50 (synapse-zvec-stage1)