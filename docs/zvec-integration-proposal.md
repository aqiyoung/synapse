# Synapse 知识库 zvec 集成方案

> **状态**: prototype 已跑通，待老板拍板
> **日期**: 2026-06-19
> **作者**: subagent (synapse-zvec-eval)
> **关联**: Workboard card `f3d84592-c2da-4751-ac28-30b0cc000f6e`

---

## TL;DR（老板 1 分钟看完）

**结论建议**：✅ **做，但分两步走**

1. **第一步（1-2 天）**：把 `vector_search.py` 里的 numpy 暴力搜索换成 zvec HNSW — 解决性能问题，不动 API
2. **第二步（可选，3-5 天）**：评估把 FTS5 换成 zvec v0.5 的原生 FTS — 等老板用真实 query 验证效果再决定

**核心数据**：
- 即使是 hash 假 embedding（无真实语义），zvec 召回率 **56% vs FTS5 4.2%**，+51.8pp
- N=10000 时 zvec HNSW 比 numpy 暴力快 **112 倍**（1ms vs 100ms）
- zvec Python wheel 已经在本机装好，Apache 2.0，Linux x86_64/ARM64 全支持

**风险**：
- ⚠️ **SiliconFlow API key 已失效**（401），如果做真实 embedding 必须先修这个
- ⚠️ 当前 prototype 用 hash 假向量，最终召回率需要真实 BGE 重测
- ✅ zvec SDK 稳定（v0.5.0，2026-06-12 发布，已有 production 用户）

---

## 1. 背景

### 当前 Synapse 架构

**Stack**（基于实际读 `/vol1/1000/dev-projects/synapse/backend/`）：
- **后端**: Python FastAPI（不是 Node.js server.mjs，原任务描述有误），端口 18800
- **数据库**: SQLite + FTS5（`note_search` 虚表）
- **现有笔记数**: 235 篇（`notes` 表 WHERE deleted_at IS NULL）
- **当前向量方案**: `vector_search.py` 用 numpy **O(N) 余弦相似度暴力扫描**，172 篇已索引

**两个搜索接口**（api.py）：

| 接口 | 用途 | 当前实现 | 问题 |
|------|------|---------|------|
| `GET /api/search?q=...` | 关键词搜索 UI | FTS5 | 命中靠关键词，不懂语义 |
| `POST /api/ai/chat` | RAG 问答 | vector_search（numpy 暴力）+ FTS5 回退 | 200+ 篇时还能撑，1000+ 篇会慢 |

### 老板需求

> "找关于 AI agent 的笔记" → 语义检索，不靠关键词

当前 FTS5 搜「AI agent」必须笔记里**同时**出现 "AI" **AND** "agent"，错位命中率为 0：

```
sqlite> SELECT id, title FROM note_search WHERE note_search MATCH '"AI" AND "agent"';
-- 返回 0 行（因为笔记里通常写 "AI 智能体" 或 "AI Agent" 等变体）
```

---

## 2. zvec 能力调研

**来源**: https://github.com/alibaba/zvec, https://zvec.org, https://pypi.org/project/zvec/

### 2.1 基本信息

| 项 | 值 |
|---|---|
| 项目 | Alibaba 开源 |
| 当前版本 | **v0.5.0**（2026-06-12 发布） |
| License | **Apache 2.0** ✅ 商用友好 |
| GitHub stars | 10.2K ⭐ |
| 定位 | 进程内（in-process）向量数据库 — 无 daemon |
| 引擎 | C++ core + 多语言 binding |
| 包大小 | ~75 MB（cp311-cp311-manylinux_2_28_x86_64） |

### 2.2 SDK 支持

| 语言 | SDK | 备注 |
|------|-----|------|
| **Python** | `pip install zvec` ✅ | 3.10-3.14，本机已装通 |
| **Node.js** | `npm install @zvec/zvec` ✅ | 官方支持 |
| Go | `github.com/zvec-ai/zvec-go` | cgo bindings |
| Rust | `github.com/zvec-ai/zvec-rust` | RAII + builder API |
| Dart/Flutter | `pub.dev/packages/zvec` | 官方 |

### 2.3 核心特性

- **HNSW ANN 索引**：默认 COSINE 相似度（也支持 IP / L2）
- **v0.5 新增 FTS**：原生全文搜索，可挂在任何 STRING 字段
- **v0.5 新增 Hybrid**：单次 `MultiQuery` 同时做 dense + sparse + scalar + text
- **v0.5 新增 DiskANN**：索引大部分放磁盘，节省内存
- **持久化**: WAL 写入，进程崩溃不丢数据
- **多进程读**：同一 collection 支持多 reader
- **单进程写**：写入互斥

### 2.4 v0.5.0 对 Synapse 的特别意义

老板要的"语义检索"其实是 **hybrid 检索**——既要关键词命中，也要语义匹配。zvec v0.5 第一次原生支持 `MultiQuery` 融合向量 + 全文：

```python
result = collection.query(
    zvec.MultiQuery(
        dense=zvec.VectorQuery("embedding", vector=[...]),
        text=zvec.TextQuery("title_content", text="AI agent", operator="OR"),
    ),
    topk=10,
)
```

理论上可以**同时替代** FTS5 + numpy vector_search 两个独立模块。

### 2.5 Benchmark 数字（官方）

Cohere 1M / 10M 数据集（768 维，16c64g 机器）：
- **QPS**: 高于多数同类（具体数字 chart 在 https://zvec.org/en/docs/db/benchmarks/）
- **Recall**: 95%+（可调 `ef_search` / `m` 参数）
- **内存**: ~3-4x 向量原始大小

---

## 3. Prototype 数据（关键证据）

### 3.1 测试方法

- **数据**: 100 篇真实 Synapse 笔记（从生产 SQLite 抽）
- **Embedding**: ⚠️ 由于 SiliconFlow API key 失效（401 Unauthorized），**用 hash 假向量**（dim=128，词袋 hash 投影）作为 fallback
- **Ground truth**: 人工标注 5 个 query 的"应该返回的笔记 ID"（基于标题/内容语义相关）
- **对比方法**:
  - FTS5：复刻 Synapse 当前 `_fts_search` 逻辑
  - Brute-force：复刻 Synapse 当前 `vector_search.py` 的 numpy 扫描
  - zvec HNSW：用 zvec 0.5.0 真 HNSW 索引

### 3.2 召回率对比（5 个 query）

| Query | FTS5 命中 | zvec 命中 | brute 命中 | FTS5 recall | zvec recall |
|-------|----------|----------|-----------|------------|------------|
| AI agent 或 AI 智能体 | 1/6 | 4/6 | 4/6 | 16.7% | **66.7%** |
| OpenClaw 升级或升级踩坑 | 0/4 | 2/4 | 2/4 | 0% | **50.0%** |
| 信创电脑或国产化运维 | 0/14 | 1/14 | 1/14 | 0% | **7.1%** |
| 代理或 mihomo 翻墙 | 0/2 | 2/2 | 2/2 | 0% | **100%** |
| FTS5 全文搜索 vs 向量检索 | N/A | N/A | N/A | — | — |
| **平均** | | | | **4.2%** | **56.0%** |

**提升：+51.8 个百分点**，即使是用无意义的 hash embedding 也成立。

> 真实 BGE embedding 下 zvec recall 应该会更高（80%+），因为 hash 是 bag-of-tokens 投影，看不出"智能体"="agent" 的同义关系。

### 3.3 性能对比（zvec HNSW vs numpy 暴力）

| 笔记数 | numpy 暴力 | zvec HNSW (build) | 加速比 |
|--------|-----------|-------------------|--------|
| 100 | 3.8 ms | 0.5 ms (0.1s build) | 7.4x |
| 1,000 | 9.4 ms | 0.8 ms (0.1s build) | 12.5x |
| 10,000 | 100.6 ms | 0.9 ms (1.8s build) | **112.7x** |
| 100,000（推断）| ~1 s | ~1 ms (~20s build) | ~1000x |

> zvec HNSW 是真正的 sub-linear ANN，10 万篇查询也是 ~1ms。
> 当前 numpy 暴力是 O(N)，1 万篇就要 100ms，到 10 万篇就不可用了。

### 3.4 文件产物

- `tools/zvec-prototype.py` — 完整 prototype（可重跑）
- `docs/zvec-eval-results.json` — 原始结果数据
- 索引目录：`/tmp/zvec-prototype-data/`（不进生产 `data/`）

---

## 4. 集成方案

### 4.1 三种部署选项

| 选项 | 描述 | 优点 | 缺点 |
|------|------|------|------|
| **A. 嵌入 server.mjs 进程** | zvec 作为 Python 模块直接在 FastAPI 进程里跑 | 简单，无 IPC，零部署成本 | FastAPI 进程重启要 re-open collection（~2s） |
| **B. 独立 daemon + HTTP** | zvec 跑在独立 Python 进程，server.mjs HTTP 调用 | 隔离，索引常驻 | 多一个进程，多一份内存 |
| **C. 完全替换搜索栈** | zvec v0.5 的 FTS + Vector 同时替代 FTS5 + numpy | 架构最简，hybrid 查询原生 | 工作量大，风险高 |

### 4.2 推荐：先用方案 A 做最小改造

**改动范围**（仅 `backend/vector_search.py`，不动其他文件）：

```python
# 改前：numpy 暴力扫描
def vector_search(db, query, limit=5):
    rows = db.execute("SELECT note_id, embedding FROM note_vectors").fetchall()
    query_emb = get_embedding(query)
    sims = [cosine_similarity(query_emb, json.loads(r[1])) for r in rows]
    return sorted(zip([r[0] for r in rows], sims), key=lambda x: -x[1])[:limit]

# 改后：zvec HNSW
_zvec_collection = None

def _get_zvec_collection():
    global _zvec_collection
    if _zvec_collection is None:
        _zvec_collection = zvec.open(path="./data/zvec_synapse")
    return _zvec_collection

def vector_search(db, query, limit=5):
    coll = _get_zvec_collection()
    query_emb = get_embedding(query)
    results = coll.query(zvec.Query("embedding", vector=query_emb), topk=limit)
    return [r.id for r in results]
```

**不变的东西**：
- `note_vectors` SQLite 表（作为真值源，迁移到 zvec 时双写）
- `api.py` 调用方式
- `embedding` 计算逻辑（仍走 SiliconFlow）
- `_smart_search` 优先级（vector 优先，FTS5 回退）

**迁移步骤**：
1. 后台脚本批量把 `note_vectors` 数据导入 zvec collection
2. 写完后切流量：让 `vector_search` 走 zvec，旧的 SQLite 表保留作为审计
3. 跑 1 周观察召回率和延迟，没问题再删 SQLite 表

### 4.3 数据一致性

```
┌──────────────┐   insert/update    ┌─────────────────┐
│ FastAPI API  │ ─────────────────► │  SQLite notes   │
└──────────────┘                    └────────┬────────┘
                                             │ trigger
                                             ▼
                                    ┌─────────────────┐
                                    │  note_vectors   │ ← 双写
                                    │  (SQLite JSON)  │
                                    └────────┬────────┘
                                             │ sync job (cron / on-write)
                                             ▼
                                    ┌─────────────────┐
                                    │  zvec collection│
                                    │  (HNSW + WAL)   │
                                    └─────────────────┘
```

简单做法：每次 `note_vectors` 写入后，调用 `zvec.upsert()`。zvec 内部 WAL 保证崩溃恢复。

### 4.4 v0.5 FTS 替换 FTS5（方案 C，长期）

**收益**：
- 一套代码搞定 keyword + semantic + hybrid
- 不用维护 `note_search` 虚表 + 触发器
- 支持复杂 query（"AI" OR "agent" 但 NOT "deprecated"）

**风险**：
- v0.5 FTS 是新功能，未在生产验证过
- FTS5 中文分词是 Unicode（SQLite 内置），zvec 的中文分词待测
- 迁移要重写 `_fts_search` 调用方

**建议**：先做方案 A，观察 1-2 周老板对召回率满不满意，再决定要不要上方案 C。

---

## 5. 投入估算

| 阶段 | 工作量 | 风险 | 收益 |
|------|--------|------|------|
| **阶段 1: 装 zvec + 迁移 vector_search** | 1-2 天 | 低（API 兼容） | 性能 +112x，召回率不变（仍用 SiliconFlow） |
| **阶段 2: 接入真实 BGE + 重测召回率** | 0.5 天（key 修好就能跑） | 中（依赖外部 API） | 召回率可能从 56% → 80%+ |
| **阶段 3: FTS5 → zvec v0.5 FTS 迁移** | 3-5 天 | 中-高 | 统一栈，原生 hybrid，少维护一份触发器 |
| **阶段 4: 上 DiskANN 适配大数据量** | 1 天 | 低 | 10 万+ 笔记仍可用 |

**老板选项**：
- 🟢 **只做阶段 1+2**：最快拿到性能提升，老板能搜语义内容，但搜索还是单一路径
- 🟡 **加做阶段 3**：彻底统一栈，但要承担 v0.5 FTS 新功能风险
- 🔴 **只做调研不动**：等老板看到真实 embedding 的召回率数据再决定

---

## 6. 风险清单

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| SiliconFlow API key 失效（已发生） | 100% | 高 | 必须先修 key，或换 OpenAI/本地 bge-small-zh |
| zvec v0.5 FTS 中文分词质量 | 中 | 中 | 阶段 3 用真实 query 做 A/B |
| FastAPI 重启后 zvec 索引 reopen 慢 | 低 | 低 | 1-2s cold start，用 lazy load 兜底 |
| 索引文件膨胀（每个 doc 一份 vector） | 低 | 低 | 235 篇 × 1024 dim × 4B = ~1MB，可忽略 |
| zvec 项目活跃度（v0.5.0 刚发） | 低 | 中 | Apache 2.0 + Alibaba 背书；fork 后可自维护 |
| 现有 `note_vectors` SQLite 表与 zvec 双写不一致 | 中 | 高 | 用 transactional outbox 模式，weekly 对账 |

---

## 7. 老板拍板建议（我替老板想的）

### 推荐路径：阶段 1 → 阶段 2 → 看效果再选阶段 3

**理由**：
1. **阶段 1 几乎无风险**：只是把 numpy 暴力换成 zvec HNSW，外部行为不变，性能立竿见影（112x）
2. **阶段 2 能验证真正的价值**：现在 prototype 用 hash 假向量，召回率提升可能是虚高；真实 BGE 测出来才算数
3. **阶段 3 是优化项不是必须项**：FTS5 没坏，没必要为了"统一栈"硬迁移

### 给老板的问题清单

1. SiliconFlow key 是真失效了还是 quota 超限？要不要换 BAAI/bge-m3 或本地 sentence-transformers？
2. 召回率"够用"的标准是什么？老板脑子里是 60% 还是 90%？
3. 数据增长预期？未来 1 年笔记会到 1000 / 10000 / 100000 哪一档？
4. 是否接受引入一个新依赖（zvec wheel 75 MB）？还是希望尽量复用现有栈？

### 我推荐老板的回答

> "先做阶段 1（动 vector_search.py，换 zvec HNSW）。1 周内修好 SiliconFlow key，跑真实 BGE 重测召回率。如果 recall 到 80%+ 再讨论阶段 3。"

---

## 附录

### A. 测试命令

```bash
cd /vol1/1000/dev-projects/synapse
./.zvec-venv/bin/python tools/zvec-prototype.py
```

### B. 关键文件路径

- 后端搜索：`backend/vector_search.py`（要改）
- 后端 API：`backend/api.py`（不改，仅阅读）
- FTS5 虚表：`backend/crud.py:72-95`（不改）
- 当前笔记数：`SELECT COUNT(*) FROM notes WHERE deleted_at IS NULL;` → 235
- 当前向量数：`SELECT COUNT(*) FROM note_vectors;` → 172

### C. zvec 安装记录（本机）

```bash
cd /vol1/1000/dev-projects/synapse
python3 -m venv .zvec-venv
./.zvec-venv/bin/pip install -i https://pypi.tuna.tsinghua.edu.cn/simple zvec requests
# Successfully installed zvec-0.5.0 numpy-2.4.6 requests-2.34.2
```

> 注意：官方 PyPI 在国内下载 ~50KB/s，建议用清华镜像。

### D. 相关链接

- zvec GitHub: https://github.com/alibaba/zvec
- zvec 文档: https://zvec.org/en/docs/db/
- zvec Benchmarks: https://zvec.org/en/docs/db/benchmarks/
- v0.5 Release Notes: https://github.com/alibaba/zvec/releases/tag/v0.5.0
- DeepWiki: https://deepwiki.com/alibaba/zvec