# 知识库 APP 功能扩展：统计面板 + 推送通知 + 分类管理

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** 为 Synapse 知识库 APP 添加三个核心功能：阅读统计数据面板、推送通知系统、分类文件夹管理

**Architecture:** 前端 Flutter 三个新页面 + 后端新增 API 统计/通知/分类接口。数据层新增 folders 表，通知采用本地轮询 + 后端 push 双通道。

**Tech Stack:** Flutter (Material 3) + FastAPI + SQLite + SharedPreferences

---

## 文件结构总览

### 后端 (Python)
- `backend/api.py` — 新增统计、通知、分类 API 路由
- `backend/models.py` — 新增 Folder, Notification, ReadingStats 模型
- `backend/crud.py` — 新增分类/统计/通知 CRUD 操作

### 前端 (Dart)
- `app/lib/screens/stats_screen.dart` — 阅读统计面板（新增）
- `app/lib/screens/folders_screen.dart` — 分类文件夹管理（新增）
- `app/lib/screens/settings_screen.dart` — 新增「通知设置」分区
- `app/lib/services/notification_service.dart` — 通知服务（新增）
- `app/lib/services/stats_service.dart` — 统计 API（新增）
- `app/lib/services/folder_service.dart` — 分类 API（新增）
- `app/lib/models/folder.dart` — 分类模型（新增）
- `app/lib/models/stats.dart` — 统计模型（新增）
- `app/lib/main.dart` — 新增通知初始化
- `app/lib/screens/home_screen.dart` — 新增统计/分类入口

---

## Task 1: 后端 — 新增数据模型

**Files:**
- Modify: `backend/models.py`
- Modify: `backend/crud.py`

### Step 1: 在 models.py 新增三个模型

```python
# === 分类文件夹 ===
class Folder(Base):
    __tablename__ = "folders"
    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String(100), nullable=False)
    icon = Column(String(50), default="folder")  # material icon name
    color = Column(String(7), default="#c96442")  # hex color
    parent_id = Column(Integer, ForeignKey("folders.id"), nullable=True)
    sort_order = Column(Integer, default=0)
    created_at = Column(DateTime, default=lambda: datetime.now(tz=timezone(timedelta(hours=8))))
    updated_at = Column(DateTime, default=lambda: datetime.now(tz=timezone(timedelta(hours=8))))

    notes = relationship("Note", back_populates="folder")
    children = relationship("Folder", backref=backref("parent", remote_side=[id]))

# 在 Note 模型新增外键
# folder_id = Column(Integer, ForeignKey("folders.id"), nullable=True)
# folder = relationship("Folder", back_populates="notes")


# === 阅读统计 ===
class ReadingStats(Base):
    __tablename__ = "reading_stats"
    id = Column(Integer, primary_key=True, autoincrement=True)
    note_id = Column(Integer, ForeignKey("notes.id"), nullable=False)
    read_count = Column(Integer, default=0)
    total_read_time = Column(Integer, default=0)  # seconds
    last_read_at = Column(DateTime, nullable=True)
    first_read_at = Column(DateTime, nullable=True)


# === 通知 ===
class Notification(Base):
    __tablename__ = "notifications"
    id = Column(Integer, primary_key=True, autoincrement=True)
    title = Column(String(200), nullable=False)
    body = Column(String(500), default="")
    type = Column(String(20), default="system")  # system/update/reminder
    is_read = Column(Boolean, default=False)
    action_url = Column(String(500), nullable=True)  # deep link
    created_at = Column(DateTime, default=lambda: datetime.now(tz=timezone(timedelta(hours=8))))
```

### Step 2: 在 crud.py 新增 CRUD 函数

```python
# === Folder CRUD ===
def create_folder(db, name, icon="folder", color="#c96442", parent_id=None, sort_order=0):
    folder = Folder(name=name, icon=icon, color=color, parent_id=parent_id, sort_order=sort_order)
    db.add(folder)
    db.commit()
    db.refresh(folder)
    return folder

def list_folders(db):
    return db.query(Folder).order_by(Folder.sort_order, Folder.name).all()

def update_folder(db, folder_id, **kwargs):
    folder = db.query(Folder).filter(Folder.id == folder_id).first()
    if not folder: return None
    for k, v in kwargs.items():
        if hasattr(folder, k): setattr(folder, k, v)
    db.commit()
    db.refresh(folder)
    return folder

def delete_folder(db, folder_id):
    folder = db.query(Folder).filter(Folder.id == folder_id).first()
    if not folder: return None
    # 将该分类下的笔记移到未分类
    db.query(Note).filter(Note.folder_id == folder_id).update({"folder_id": None})
    db.delete(folder)
    db.commit()
    return folder

def get_folder_notes(db, folder_id, skip=0, limit=50):
    total = db.query(Note).filter(Note.folder_id == folder_id, Note.deleted_at.is_(None)).count()
    notes = db.query(Note).filter(Note.folder_id == folder_id, Note.deleted_at.is_(None)).order_by(Note.updated_at.desc()).offset(skip).limit(limit).all()
    return total, notes

# === Stats CRUD ===
def record_read(db, note_id):
    """记录一次阅读"""
    stat = db.query(ReadingStats).filter(ReadingStats.note_id == note_id).first()
    now = datetime.now(tz=timezone(timedelta(hours=8)))
    if not stat:
        stat = ReadingStats(note_id=note_id, read_count=1, first_read_at=now, last_read_at=now)
        db.add(stat)
    else:
        stat.read_count += 1
        stat.last_read_at = now
    db.commit()

def get_reading_stats(db, note_id):
    return db.query(ReadingStats).filter(ReadingStats.note_id == note_id).first()

def get_overall_stats(db):
    """全局阅读统计"""
    total_notes = db.query(Note).filter(Note.deleted_at.is_(None)).count()
    total_tags = db.query(Tag).count()
    total_reads = db.query(func.sum(ReadingStats.read_count)).scalar() or 0
    total_read_time = db.query(func.sum(ReadingStats.total_read_time)).scalar() or 0
    # 最近 7 天阅读
    week_ago = datetime.now(tz=timezone(timedelta(hours=8))) - timedelta(days=7)
    recent_reads = db.query(func.sum(ReadingStats.read_count)).filter(ReadingStats.last_read_at >= week_ago).scalar() or 0
    # 热门笔记
    hot_notes = db.query(Note, ReadingStats.read_count).join(ReadingStats).filter(Note.deleted_at.is_(None)).order_by(ReadingStats.read_count.desc()).limit(10).all()
    # 每日阅读趋势（最近 30 天）
    daily = db.query(
        func.date(ReadingStats.last_read_at).label('date'),
        func.sum(ReadingStats.read_count).label('count')
    ).filter(ReadingStats.last_read_at >= datetime.now(tz=timezone(timedelta(hours=8))) - timedelta(days=30)).group_by(func.date(ReadingStats.last_read_at)).all()
    return {
        "total_notes": total_notes,
        "total_tags": total_tags,
        "total_reads": total_reads,
        "total_read_time": total_read_time,
        "recent_reads": recent_reads,
        "hot_notes": [{"id": n.id, "title": n.title, "reads": c} for n, c in hot_notes],
        "daily_trend": [{"date": str(d.date), "count": d.count} for d in daily],
    }

# === Notification CRUD ===
def create_notification(db, title, body="", type="system", action_url=None):
    notif = Notification(title=title, body=body, type=type, action_url=action_url)
    db.add(notif)
    db.commit()
    db.refresh(notif)
    return notif

def list_notifications(db, limit=50, unread_only=False):
    q = db.query(Notification)
    if unread_only:
        q = q.filter(Notification.is_read == False)
    return q.order_by(Notification.created_at.desc()).limit(limit).all()

def mark_read(db, notif_id):
    notif = db.query(Notification).filter(Notification.id == notif_id).first()
    if notif:
        notif.is_read = True
        db.commit()
    return notif

def mark_all_read(db):
    db.query(Notification).filter(Notification.is_read == False).update({"is_read": True})
    db.commit()
```

### Step 3: 提交

```bash
cd /vol1/1000/dev-projects/synapse
git add backend/
git commit -m "feat: add Folder, ReadingStats, Notification models + CRUD"
```

---

## Task 2: 后端 — 新增 API 路由

**Files:**
- Modify: `backend/api.py`

### Step 1: 新增统计 API

```python
# ===== 阅读统计 API =====

@app.get("/api/stats")
def api_stats(db: Session = Depends(get_db)):
    """全局阅读统计"""
    return get_overall_stats(db)

@app.get("/api/stats/note/{note_id}")
def api_note_stats(note_id: int, db: Session = Depends(get_db)):
    """单篇笔记阅读统计"""
    stat = get_reading_stats(db, note_id)
    if not stat:
        return {"read_count": 0, "total_read_time": 0, "last_read_at": None, "first_read_at": None}
    return {
        "read_count": stat.read_count,
        "total_read_time": stat.total_read_time,
        "last_read_at": stat.last_read_at.isoformat() if stat.last_read_at else None,
        "first_read_at": stat.first_read_at.isoformat() if stat.first_read_at else None,
    }

@app.post("/api/stats/note/{note_id}/read")
def api_record_read(note_id: int, db: Session = Depends(get_db)):
    """记录一次阅读"""
    note = get_note(db, note_id)
    if not note:
        raise HTTPException(404, "笔记不存在")
    record_read(db, note_id)
    return {"ok": True}
```

### Step 2: 新增分类 API

```python
# ===== 分类文件夹 API =====

class FolderCreate(BaseModel):
    name: str
    icon: str = "folder"
    color: str = "#c96442"
    parent_id: Optional[int] = None

class FolderUpdate(BaseModel):
    name: Optional[str] = None
    icon: Optional[str] = None
    color: Optional[str] = None
    parent_id: Optional[int] = None
    sort_order: Optional[int] = None

@app.get("/api/folders")
def api_list_folders(db: Session = Depends(get_db)):
    """列出所有分类"""
    folders = list_folders(db)
    return [f.to_dict() for f in folders]

@app.post("/api/folders")
def api_create_folder(data: FolderCreate, db: Session = Depends(get_db)):
    """创建分类"""
    folder = create_folder(db, name=data.name, icon=data.icon, color=data.color, parent_id=data.parent_id)
    return folder.to_dict()

@app.put("/api/folders/{folder_id}")
def api_update_folder(folder_id: int, data: FolderUpdate, db: Session = Depends.get_db)):
    """更新分类"""
    kwargs = {k: v for k, v in data.dict().items() if v is not None}
    folder = update_folder(db, folder_id, **kwargs)
    if not folder:
        raise HTTPException(404, "分类不存在")
    return folder.to_dict()

@app.delete("/api/folders/{folder_id}")
def api_delete_folder(folder_id: int, db: Session = Depends(get_db)):
    """删除分类"""
    folder = delete_folder(db, folder_id)
    if not folder:
        raise HTTPException(404, "分类不存在")
    return {"ok": True, "deleted": folder.name}

@app.get("/api/folders/{folder_id}/notes")
def api_folder_notes(
    folder_id: int,
    skip: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
    db: Session = Depends(get_db),
):
    """获取分类下的笔记"""
    total, notes = get_folder_notes(db, folder_id, skip=skip, limit=limit)
    return {"total": total, "notes": [n.to_dict() for n in notes]}

@app.put("/api/notes/{note_id}/folder")
def api_set_note_folder(note_id: int, folder_id: Optional[int] = None, db: Session = Depends(get_db)):
    """设置笔记分类"""
    note = get_note(db, note_id)
    if not note:
        raise HTTPException(404, "笔记不存在")
    note.folder_id = folder_id
    db.commit()
    db.refresh(note)
    return {"ok": True, "folder_id": folder_id}
```

### Step 3: 新增通知 API

```python
# ===== 通知 API =====

@app.get("/api/notifications")
def api_list_notifications(
    limit: int = Query(50, ge=1, le=200),
    unread_only: bool = Query(False),
    db: Session = Depends(get_db),
):
    """获取通知列表"""
    notifs = list_notifications(db, limit=limit, unread_only=unread_only)
    return [n.to_dict() for n in notifs]

@app.get("/api/notifications/unread-count")
def api_unread_count(db: Session = Depends(get_db)):
    """未读通知数"""
    count = db.query(Notification).filter(Notification.is_read == False).count()
    return {"count": count}

@app.post("/api/notifications/{notif_id}/read")
def api_mark_read(notif_id: int, db: Session = Depends(get_db)):
    """标记已读"""
    mark_read(db, notif_id)
    return {"ok": True}

@app.post("/api/notifications/read-all")
def api_mark_all_read(db: Session = Depends(get_db)):
    """全部已读"""
    mark_all_read(db)
    return {"ok": True}

@app.delete("/api/notifications/{notif_id}")
def api_delete_notification(notif_id: int, db: Session = Depends(get_db)):
    """删除通知"""
    notif = db.query(Notification).filter(Notification.id == notif_id).first()
    if not notif:
        raise HTTPException(404, "通知不存在")
    db.delete(notif)
    db.commit()
    return {"ok": True}
```

### Step 4: 提交

```bash
git add backend/
git commit -m "feat: add stats, folders, notifications API routes"
```

---

## Task 3: 前端 — 数据模型 + API 服务

**Files:**
- Create: `app/lib/models/folder.dart`
- Create: `app/lib/models/stats.dart`
- Create: `app/lib/services/stats_service.dart`
- Create: `app/lib/services/folder_service.dart`
- Create: `app/lib/services/notification_service.dart`

### Step 1: 分类模型 (folder.dart)

```dart
class Folder {
  final int id;
  final String name;
  final String icon;
  final String color;
  final int? parentId;
  final int sortOrder;
  final int noteCount;
  final DateTime? createdAt;

  Folder({
    required this.id,
    required this.name,
    this.icon = 'folder',
    this.color = '#c96442',
    this.parentId,
    this.sortOrder = 0,
    this.noteCount = 0,
    this.createdAt,
  });

  factory Folder.fromJson(Map<String, dynamic> json) => Folder(
    id: json['id'] ?? 0,
    name: json['name'] ?? '',
    icon: json['icon'] ?? 'folder',
    color: json['color'] ?? '#c96442',
    parentId: json['parent_id'],
    sortOrder: json['sort_order'] ?? 0,
    noteCount: json['note_count'] ?? 0,
    createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at']) : null,
  );
}
```

### Step 2: 统计模型 (stats.dart)

```dart
class ReadingStats {
  final int noteId;
  final int readCount;
  final int totalReadTime;
  final DateTime? lastReadAt;
  final DateTime? firstReadAt;

  ReadingStats({
    required this.noteId,
    this.readCount = 0,
    this.totalReadTime = 0,
    this.lastReadAt,
    this.firstReadAt,
  });

  factory ReadingStats.fromJson(Map<String, dynamic> json) => ReadingStats(
    noteId: json['note_id'] ?? 0,
    readCount: json['read_count'] ?? 0,
    totalReadTime: json['total_read_time'] ?? 0,
    lastReadAt: json['last_read_at'] != null ? DateTime.tryParse(json['last_read_at']) : null,
    firstReadAt: json['first_read_at'] != null ? DateTime.tryParse(json['first_read_at']) : null,
  );
}

class OverallStats {
  final int totalNotes;
  final int totalTags;
  final int totalReads;
  final int totalReadTime;
  final int recentReads;
  final List<Map<String, dynamic>> hotNotes;
  final List<Map<String, dynamic>> dailyTrend;

  OverallStats({
    required this.totalNotes,
    required this.totalTags,
    required this.totalReads,
    required this.totalReadTime,
    required this.recentReads,
    required this.hotNotes,
    required this.dailyTrend,
  });

  factory OverallStats.fromJson(Map<String, dynamic> json) => OverallStats(
    totalNotes: json['total_notes'] ?? 0,
    totalTags: json['total_tags'] ?? 0,
    totalReads: json['total_reads'] ?? 0,
    totalReadTime: json['total_read_time'] ?? 0,
    recentReads: json['recent_reads'] ?? 0,
    hotNotes: List<Map<String, dynamic>>.from(json['hot_notes'] ?? []),
    dailyTrend: List<Map<String, dynamic>>.from(json['daily_trend'] ?? []),
  );
}
```

### Step 3: 统计 API 服务 (stats_service.dart)

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/stats.dart';
import 'api_service.dart';

class StatsService {
  static Future<OverallStats> getOverall() async {
    final r = await http.get(Uri.parse('${ApiService.baseUrl}/stats'), headers: ApiService._headers);
    if (r.statusCode == 200) {
      return OverallStats.fromJson(json.decode(r.body));
    }
    throw Exception('获取统计失败');
  }

  static Future<ReadingStats> getNoteStats(int noteId) async {
    final r = await http.get(Uri.parse('${ApiService.baseUrl}/stats/note/$noteId'), headers: ApiService._headers);
    if (r.statusCode == 200) {
      return ReadingStats.fromJson(json.decode(r.body));
    }
    return ReadingStats(noteId: noteId);
  }

  static Future<void> recordRead(int noteId) async {
    await http.post(Uri.parse('${ApiService.baseUrl}/stats/note/$noteId/read'), headers: ApiService._headers);
  }
}
```

### Step 4: 分类 API 服务 (folder_service.dart)

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/folder.dart';
import '../models/note.dart';
import 'api_service.dart';

class FolderService {
  static Future<List<Folder>> getFolders() async {
    final r = await http.get(Uri.parse('${ApiService.baseUrl}/folders'), headers: ApiService._headers);
    if (r.statusCode == 200) {
      return (json.decode(r.body) as List).map((e) => Folder.fromJson(e)).toList();
    }
    return [];
  }

  static Future<Folder?> createFolder({required String name, String icon = 'folder', String color = '#c96442', int? parentId}) async {
    final r = await http.post(Uri.parse('${ApiService.baseUrl}/folders'),
      headers: ApiService._headers,
      body: json.encode({'name': name, 'icon': icon, 'color': color, 'parent_id': parentId}),
    );
    if (r.statusCode == 200) return Folder.fromJson(json.decode(r.body));
    return null;
  }

  static Future<bool> updateFolder(int id, {String? name, String? icon, String? color, int? parentId, int? sortOrder}) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (icon != null) body['icon'] = icon;
    if (color != null) body['color'] = color;
    if (parentId != null) body['parent_id'] = parentId;
    if (sortOrder != null) body['sort_order'] = sortOrder;
    final r = await http.put(Uri.parse('${ApiService.baseUrl}/folders/$id'),
      headers: ApiService._headers,
      body: json.encode(body),
    );
    return r.statusCode == 200;
  }

  static Future<bool> deleteFolder(int id) async {
    final r = await http.delete(Uri.parse('${ApiService.baseUrl}/folders/$id'), headers: ApiService._headers);
    return r.statusCode == 200;
  }

  static Future<List<Note>> getFolderNotes(int folderId) async {
    final r = await http.get(Uri.parse('${ApiService.baseUrl}/folders/$folderId/notes'), headers: ApiService._headers);
    if (r.statusCode == 200) {
      final data = json.decode(r.body);
      return (data['notes'] as List).map((n) => Note.fromJson(n)).toList();
    }
    return [];
  }

  static Future<bool> setNoteFolder(int noteId, int? folderId) async {
    final r = await http.put(Uri.parse('${ApiService.baseUrl}/notes/$noteId/folder'),
      headers: ApiService._headers,
      body: json.encode({'folder_id': folderId}),
    );
    return r.statusCode == 200;
  }
}
```

### Step 5: 通知服务 (notification_service.dart)

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

class AppNotification {
  final int id;
  final String title;
  final String body;
  final String type;
  final bool isRead;
  final String? actionUrl;
  final DateTime createdAt;

  AppNotification({
    required this.id,
    required this.title,
    this.body = '',
    this.type = 'system',
    this.isRead = false,
    this.actionUrl,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
    id: json['id'] ?? 0,
    title: json['title'] ?? '',
    body: json['body'] ?? '',
    type: json['type'] ?? 'system',
    isRead: json['is_read'] ?? false,
    actionUrl: json['action_url'],
    createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at']) ?? DateTime.now() : DateTime.now(),
  );
}

class NotificationService {
  static const _enabledKey = 'notifications_enabled';
  static const _intervalKey = 'notification_interval_minutes';

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }

  static Future<List<AppNotification>> getNotifications({bool unreadOnly = false}) async {
    var url = '${ApiService.baseUrl}/notifications?limit=50';
    if (unreadOnly) url += '&unread_only=true';
    final r = await http.get(Uri.parse(url), headers: ApiService._headers);
    if (r.statusCode == 200) {
      return (json.decode(r.body) as List).map((e) => AppNotification.fromJson(e)).toList();
    }
    return [];
  }

  static Future<int> getUnreadCount() async {
    final r = await http.get(Uri.parse('${ApiService.baseUrl}/notifications/unread-count'), headers: ApiService._headers);
    if (r.statusCode == 200) {
      return json.decode(r.body)['count'] ?? 0;
    }
    return 0;
  }

  static Future<void> markRead(int id) async {
    await http.post(Uri.parse('${ApiService.baseUrl}/notifications/$id/read'), headers: ApiService._headers);
  }

  static Future<void> markAllRead() async {
    await http.post(Uri.parse('${ApiService.baseUrl}/notifications/read-all'), headers: ApiService._headers);
  }

  static Future<void> deleteNotification(int id) async {
    await http.delete(Uri.parse('${ApiService.baseUrl}/notifications/$id'), headers: ApiService._headers);
  }
}
```

### Step 6: 提交

```bash
git add app/
git commit -m "feat: add folder/stats/notification models and API services"
```

---

## Task 4: 前端 — 阅读统计面板

**Files:**
- Create: `app/lib/screens/stats_screen.dart`

### Step 1: 创建统计面板页面

一个滚动页面，包含以下卡片：
1. **概览卡片** — 总笔记数、总标签数、总阅读次数、总阅读时长
2. **最近 7 天阅读趋势** — 简单柱状图（用 Container + Row 实现，不依赖图表库）
3. **热门笔记 Top 10** — 列表，显示标题 + 阅读次数
4. **单篇笔记统计**（可选，在笔记详情页调用）

布局要求：
- 使用 Material 3 Card 风格
- 数字用大号字体突出
- 柱状图用 Container 高度百分比实现
- 主题色跟随 AppTheme

```dart
// stats_screen.dart 核心结构
class StatsScreen extends StatefulWidget {
  final int themeIndex;
  const StatsScreen({super.key, required this.themeIndex});
  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  OverallStats? _stats;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await StatsService.getOverall();
      setState(() { _stats = s; _loading = false; });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.presets[widget.themeIndex];
    // Scaffold + AppBar + body
    // 4 个概览卡片 GridView (2x2)
    // 趋势柱状图 Card
    // 热门笔记列表 Card
  }
}
```

### Step 2: 提交

```bash
git add app/
git commit -m "feat: add stats dashboard screen"
```

---

## Task 5: 前端 — 分类文件夹管理

**Files:**
- Create: `app/lib/screens/folders_screen.dart`

### Step 1: 创建分类管理页面

功能：
1. **分类列表** — 显示所有分类（图标 + 名称 + 笔记数）
2. **新建分类** — 弹窗表单（名称 + 图标选择 + 颜色选择）
3. **编辑分类** — 长按或点击编辑按钮
4. **删除分类** — 确认弹窗
5. **分类详情** — 进入分类查看笔记列表
6. **笔记分类** — 在笔记详情页加分类选择器

```dart
// folders_screen.dart 核心结构
class FoldersScreen extends StatefulWidget {
  final int themeIndex;
  const FoldersScreen({super.key, required this.themeIndex});
  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen> {
  List<Folder> _folders = [];
  bool _loading = true;

  // CRUD operations via FolderService
  // List view with ListTile
  // FAB for create
  // Dialog for edit/create
}
```

### Step 2: 在笔记详情页添加分类选择器

在 `note_detail_screen.dart` 的标题下方添加一个分类 Chip，点击可切换分类。

### Step 3: 在首页添加分类筛选

在 `home_screen.dart` 的标签筛选旁添加分类筛选下拉。

### Step 4: 提交

```bash
git add app/
git commit -m "feat: add folder management screen + note folder selector"
```

---

## Task 6: 前端 — 推送通知

**Files:**
- Modify: `app/lib/screens/settings_screen.dart` — 新增通知设置分区
- Modify: `app/lib/main.dart` — 新增通知初始化 + 轮询

### Step 1: 设置页新增通知分区

在 SettingsScreen 的 `_buildSettingsList` 中新增：

```dart
Widget _buildNotificationSection() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ListTile(
        leading: const Icon(Icons.notifications_outlined),
        title: const Text('推送通知'),
        trailing: Switch(
          value: _notificationsEnabled,
          onChanged: (v) async {
            await NotificationService.setEnabled(v);
            setState(() => _notificationsEnabled = v);
          },
        ),
      ),
      ListTile(
        leading: const Icon(Icons.notifications_active_outlined),
        title: const Text('未读通知'),
        subtitle: Text('$_unreadCount 条未读'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsScreen())),
      ),
    ],
  );
}
```

### Step 2: 通知列表页

创建 `app/lib/screens/notifications_screen.dart`：
- 通知列表（标题 + 内容 + 时间 + 已读状态）
- 点击标记已读
- 全部已读按钮
- 删除按钮

### Step 3: main.dart 添加通知轮询

```dart
// 在 main() 中
NotificationService.isEnabled().then((enabled) {
  if (enabled) _startNotificationPolling();
});

void _startNotificationPolling() {
  Timer.periodic(const Duration(minutes: 5), (_) async {
    final count = await NotificationService.getUnreadCount();
    if (count > 0) {
      // 显示本地通知或更新 badge
    }
  });
}
```

### Step 4: 提交

```bash
git add app/
git commit -m "feat: add notification system + settings notification section"
```

---

## Task 7: 入口集成 + 图标替换

**Files:**
- Modify: `app/lib/screens/home_screen.dart` — 新增统计/分类入口按钮
- Modify: `app/lib/screens/mine_screen.dart` — 新增统计/分类/通知入口
- Create: 图标 PNG 文件（各分辨率）

### Step 1: 我的页面新增入口

在 MineScreen 的菜单列表中新增：
- 📊 阅读统计 → StatsScreen
- 📂 分类管理 → FoldersScreen
- 🔔 通知中心 → NotificationsScreen

### Step 2: 首页快捷入口

在 HomeScreen 的 AppBar 添加统计按钮（点击跳转 StatsScreen）

### Step 3: 图标替换

将极简版 SVG 图标转为各分辨率 PNG：
```bash
# 用 Python 生成
python3 -c "
from PIL import Image, ImageDraw
sizes = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
for density, size in sizes.items():
    img = Image.new('RGBA', (size, size), (0,0,0,0))
    draw = ImageDraw.Draw(img)
    # 画一个简洁的文件夹+齿轮图标
    # 外圈圆形
    draw.ellipse([4, 4, size-4, size-4], fill=(201, 100, 66, 255))
    # 内部齿轮线条
    cx, cy = size//2, size//2
    r = size//3
    for i in range(8):
        angle = i * 3.14159 / 4
        x1 = cx + int(r * 0.6 * __import__('math').cos(angle))
        y1 = cy + int(r * 0.6 * __import__('math').sin(angle))
        x2 = cx + int(r * __import__('math').cos(angle))
        y2 = cy + int(r * __import__('math').sin(angle))
        draw.line([(x1,y1),(x2,y2)], fill=(255,255,255,255), width=max(2, size//24))
    # 中心点
    draw.ellipse([cx-3, cy-3, cx+3, cy+3], fill=(255,255,255,255))
    img.save(f'assets/icons/ic_launcher_{density}.png')
"
```

然后更新 `android/app/src/main/AndroidManifest.xml` 使用本地图标。

### Step 4: 提交

```bash
git add app/ android/
git commit -m "feat: add navigation entries + replace app icon"
```

---

## Task 8: 构建 + 推送

### Step 1: 推送代码

```bash
cd /vol1/1000/dev-projects/synapse
git push origin beta
```

### Step 2: 创建 PR

```bash
gh pr create --title "feat: stats dashboard + notifications + folder management" --body "..."
```

### Step 3: 构建 APK

触发 GitHub Actions 构建，确认通过。
