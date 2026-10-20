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
        final body = await response.stream.bytesToString().timeout(
          const Duration(seconds: 60),
        );
        throw DeepSeekException(
          'DeepSeek request failed (${response.statusCode}): $body',
          statusCode: response.statusCode,
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

  /// One non-streaming request whose reply is a JSON object, returned as text.
  static Future<String> completeJson({
    required String apiKey,
    required List<AiDiscussionMessage> messages,
    http.Client? client,
  }) async {
    final trimmedApiKey = apiKey.trim();
    if (trimmedApiKey.isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'API key cannot be empty.');
    }
    final requestClient = client ?? http.Client();
    try {
      final response = await requestClient
          .post(
            _chatCompletionsUri,
            headers: {
              'Authorization': 'Bearer $trimmedApiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': 'deepseek-chat',
              'stream': false,
              'temperature': 0,
              'max_tokens': 2000,
              'response_format': {'type': 'json_object'},
              'messages': messages.map((m) => m.toJson()).toList(),
            }),
          )
          .timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DeepSeekException(
          'DeepSeek request failed (${response.statusCode}): ${response.body}',
          statusCode: response.statusCode,
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final choices = decoded is Map ? decoded['choices'] : null;
      final first = choices is List && choices.isNotEmpty
          ? choices.first
          : null;
      final message = first is Map ? first['message'] : null;
      final content = message is Map ? message['content'] : null;
      if (content is! String || content.trim().isEmpty) {
        throw const FormatException('DeepSeek returned an empty answer.');
      }
      return content;
    } finally {
      if (client == null) requestClient.close();
    }
  }
}

class DeepSeekException implements Exception {
  final String message;
  final int? statusCode;

  const DeepSeekException(this.message, {this.statusCode});

  bool get isAuthError => statusCode == 401;

  @override
  String toString() => message;
}
