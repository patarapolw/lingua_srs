import 'saved_time.dart';

class AiDiscussionMessage {
  final String role;
  final String content;
  final DateTime? createdAt;

  const AiDiscussionMessage({
    required this.role,
    required this.content,
    this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    if (createdAt != null) 'createdAt': savedTime(createdAt!),
  };

  factory AiDiscussionMessage.fromJson(Map<String, dynamic> json) {
    final role = json['role'];
    final content = json['content'];
    final createdAt = json['createdAt'];
    if (role is! String ||
        content is! String ||
        (createdAt != null && createdAt is! String)) {
      throw const FormatException('Invalid AI discussion message.');
    }
    final parsedCreatedAt = createdAt == null ? null : tryLoadedTime(createdAt);
    if (createdAt != null && parsedCreatedAt == null) {
      throw const FormatException('Invalid AI discussion message timestamp.');
    }
    return AiDiscussionMessage(
      role: role,
      content: content,
      createdAt: parsedCreatedAt,
    );
  }
}
