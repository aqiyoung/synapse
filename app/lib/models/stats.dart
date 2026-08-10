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
    lastReadAt:
        json['last_read_at'] != null
            ? DateTime.tryParse(json['last_read_at'])
            : null,
    firstReadAt:
        json['first_read_at'] != null
            ? DateTime.tryParse(json['first_read_at'])
            : null,
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
