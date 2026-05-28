class Note {
  final int id;
  final String title;
  final String content;
  final String summary;
  final List<String> tags;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  Note({
    required this.id,
    required this.title,
    this.content = '',
    this.summary = '',
    this.tags = const [],
    this.createdAt,
    this.updatedAt,
  });

  factory Note.fromJson(Map<String, dynamic> json) {
    return Note(
      id: json['id'] ?? 0,
      title: json['title'] ?? '无标题',
      content: json['content'] ?? '',
      summary: json['summary'] ?? '',
      tags: List<String>.from(json['tags'] ?? []),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'])
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'])
          : null,
    );
  }
}

class Tag {
  final int id;
  final String name;
  final String color;
  final int noteCount;

  Tag({
    required this.id,
    required this.name,
    this.color = '#c96442',
    this.noteCount = 0,
  });

  factory Tag.fromJson(Map<String, dynamic> json) {
    return Tag(
      id: json['id'] ?? 0,
      name: json['name'] ?? '',
      color: json['color'] ?? '#c96442',
      noteCount: json['note_count'] ?? 0,
    );
  }
}

class Relations {
  final List<Map<String, dynamic>> outgoing;
  final List<Map<String, dynamic>> incoming;

  Relations({this.outgoing = const [], this.incoming = const []});

  factory Relations.fromJson(Map<String, dynamic> json) {
    return Relations(
      outgoing: List<Map<String, dynamic>>.from(json['outgoing'] ?? []),
      incoming: List<Map<String, dynamic>>.from(json['incoming'] ?? []),
    );
  }
}
