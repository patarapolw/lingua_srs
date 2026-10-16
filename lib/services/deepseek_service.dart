import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_discussion_message.dart';

class DeepSeekService {
  static final Uri _chatCompletionsUri = Uri.https(
    'api.deepseek.com',
    '/chat/completions',
  );

  static Stream<String> replyStream({
    required String apiKey,
    required List<AiDiscussionMessage> messages,
    http.Client? client,
  }) async* {
    final trimmedApiKey = apiKey.trim();
    if (trimmedApiKey.isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'API key cannot be empty.');
    }

    final requestClient = client ?? http.Client();
    try {
      final request = http.Request('POST', _chatCompletionsUri)
        ..headers.addAll({
          'Authorization': 'Bearer $trimmedApiKey',
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
        })
        ..body = jsonEncode({
          'model': 'deepseek-chat',
          'stream': true,
          'messages': messages.map((message) => message.toJson()).toList(),
        });

      final response = await requestClient
          .send(request)
          .timeout(const Duration(seconds: 60));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream
            .bytesToString()
            .timeout(const Duration(seconds: 60));
        throw DeepSeekException(
          'DeepSeek request failed (${response.statusCode}): $body',
        );
      }

      var receivedContent = false;
      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(const Duration(seconds: 60))) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;

        final decoded = jsonDecode(data);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException(
            'DeepSeek returned an invalid stream event.',
          );
        }
        if (decoded['error'] != null) {
          throw DeepSeekException(
            'DeepSeek request failed: ${decoded['error']}',
          );
        }
        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty || choices.first is! Map) {
          continue;
        }
        final delta = choices.first['delta'];
        final content = delta is Map ? delta['content'] : null;
        if (content is String && content.isNotEmpty) {
          receivedContent = true;
          yield content;
        }
      }

      if (!receivedContent) {
        throw const FormatException('DeepSeek returned an empty answer.');
      }
    } finally {
      if (client == null) requestClient.close();
    }
  }
}

class DeepSeekException implements Exception {
  final String message;

  const DeepSeekException(this.message);

  @override
  String toString() => message;
}
