import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lingua_srs/models/ai_discussion_message.dart';
import 'package:lingua_srs/services/deepseek_service.dart';
import 'package:lingua_srs/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeepSeek discussions', () {
    test('streams saved conversation context from DeepSeek', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url, Uri.https('api.deepseek.com', '/chat/completions'));
        expect(request.headers['Authorization'], 'Bearer test-key');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'deepseek-chat');
        expect(body['stream'], isTrue);
        expect(body['messages'], [
          {'role': 'system', 'content': 'You are a tutor.'},
          {'role': 'user', 'content': 'What does this word mean?'},
        ]);
        return http.Response(
          [
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': 'It means '},
                },
              ],
            })}',
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '**a helpful thing.**'},
                },
              ],
            })}',
            'data: [DONE]',
            '',
          ].join('\n\n'),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });

      final chunks = await DeepSeekService.replyStream(
        apiKey: ' test-key ',
        messages: const [
          AiDiscussionMessage(role: 'system', content: 'You are a tutor.'),
          AiDiscussionMessage(
            role: 'user',
            content: 'What does this word mean?',
          ),
        ],
        client: client,
      ).toList();

      expect(chunks, ['It means ', '**a helpful thing.**']);
      client.close();
    });

    test('reports unsuccessful API responses', () async {
      final client = MockClient(
        (_) async => http.Response('invalid API key', 401),
      );

      await expectLater(
        DeepSeekService.replyStream(
          apiKey: 'test-key',
          messages: const [
            AiDiscussionMessage(role: 'user', content: 'Question'),
          ],
          client: client,
        ).toList(),
        throwsA(isA<DeepSeekException>()),
      );
      client.close();
    });

    test('persists API key and saved conversation threads', () async {
      SharedPreferences.setMockInitialValues({});

      await StorageService.saveDeepSeekApiKey(' test-key ');
      expect(await StorageService.loadDeepSeekApiKey(), 'test-key');

      final updatedAt = DateTime.utc(2026, 10, 17, 12);
      final messages = [
        AiDiscussionMessage(role: 'user', content: 'Question'),
        AiDiscussionMessage(
          role: 'assistant',
          content: 'Answer',
          createdAt: updatedAt,
        ),
      ];
      await StorageService.saveAiDiscussions({'vocab:sentence': messages});
      final restored = await StorageService.loadAiDiscussions();
      expect(restored['vocab:sentence']?.map((message) => message.content), [
        'Question',
        'Answer',
      ]);
      expect(restored['vocab:sentence']?.last.createdAt, updatedAt);

      expect(
        AiDiscussionMessage.fromJson({'role': 'user', 'content': 'Legacy'})
            .createdAt,
        isNull,
      );

      await StorageService.saveAiDiscussions({});
      expect(await StorageService.loadAiDiscussions(), isEmpty);
      await StorageService.saveDeepSeekApiKey('');
      expect(await StorageService.loadDeepSeekApiKey(), isEmpty);
    });
  });
}
