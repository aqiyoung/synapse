# 知识库 App

基于 Flutter 的知识库移动端应用，对接 FastAPI 后端 API。

## 功能

- 📚 笔记列表浏览、搜索、标签筛选
- 📖 笔记详情查看（Markdown 渲染）
- 🕸️ 知识图谱可视化
- 🏥 健康检查（断链检测、孤立笔记）
- 🌙 暗色模式
- ⚙️ 服务器地址配置

## 开发

```bash
# 安装依赖
flutter pub get

# 运行调试
flutter run

# 构建 APK
flutter build apk --release
```

## GitHub Actions 自动构建

推送到 `main` 分支后，GitHub Actions 会自动：
1. 编译 Release APK
2. 上传到 Artifacts
3. 创建 Release（带 APK 附件）

## 项目结构

```
app/
├── lib/
│   ├── main.dart              # 入口
│   ├── models/                # 数据模型
│   ├── screens/               # 页面
│   │   ├── home_screen.dart   # 首页（笔记列表）
│   │   ├── note_detail_screen.dart  # 笔记详情
│   │   ├── graph_screen.dart  # 知识图谱
│   │   ├── lint_screen.dart   # 健康检查
│   │   └── settings_screen.dart  # 设置
│   ├── services/              # API 服务
│   └── widgets/               # 组件
├── android/                   # Android 配置
└── ios/                       # iOS 配置
```

## 配置

App 默认连接 `https://wiki.threel.site`，可在设置页面修改服务器地址。
