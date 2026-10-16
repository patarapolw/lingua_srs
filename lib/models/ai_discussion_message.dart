class AiDiscussionMessage {
  final String role;
  final String content;

  const AiDiscussionMessage({required this.role, required this.content});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};

  factory AiDiscussionMessage.fromJson(Map<String, dynamic> json) {
    final role = json['role'];
    final content = json['content'];
    if (role is! String || content is! String) {
      throw const FormatException('Invalid AI discussion message.');
    }
    return AiDiscussionMessage(role: role, content: content);
  }
}
