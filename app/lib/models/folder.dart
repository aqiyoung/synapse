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
    createdAt:
        json['created_at'] != null
            ? DateTime.tryParse(json['created_at'])
            : null,
  );
}
