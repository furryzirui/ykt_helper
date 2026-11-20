import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/services/ai_answer.dart';

class AiAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  dynamic modelsData = {
    'data': [
      {'id': 'vision-test'},
    ],
  };
  int statusCode = 200;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(
        options.path.endsWith('/models')
            ? modelsData
            : {
                'choices': [
                  {
                    'message': {'content': 'A'},
                  },
                ],
              },
      ),
      statusCode,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'question figures are attached even when no course slides are sent',
    () async {
      final adapter = AiAdapter();
      final service = AiAnswerService(
        client: Dio()..httpClientAdapter = adapter,
      );
      final downloaded = <String>[];
      await service.generate(
        settings: AppSettings(
          baseUrl: 'https://ai.example.com/v1',
          model: 'vision',
        ),
        question: const Question(
          id: 'q',
          body: '图中是什么？<img src="https://example.com/question.png">',
          type: 5,
        ),
        slides: const [],
        loadImage: (url) async {
          downloaded.add(url);
          return Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
        },
      );
      expect(downloaded, ['https://example.com/question.png']);
      final content = array(
        object(
          array(object(adapter.requests.single.data)['messages']).first,
        )['content'],
      );
      expect(content.length, 2);
      expect(
        str(object(content.first)['text']),
        isNot(contains('可以参考课程课件进行完成')),
      );
    },
  );
  const q = Question(
    id: 'q',
    body: '题目',
    type: 2,
    options: {'A': '甲', 'B': '乙', 'C': '丙'},
  );
  const slides = [
    Slide(id: '1', index: 0, imageUrl: 'https://example.com/1.png'),
    Slide(id: '2', index: 1, imageUrl: 'https://example.com/2.png'),
    Slide(id: '3', index: 2, imageUrl: 'https://example.com/3.png'),
  ];
  const deck = Presentation(id: 'p', title: '课件', slides: slides);
  test('all four attachment ranges preserve the requested pages', () {
    expect(AiAnswerService.selectedSlides(deck, 1, SlideScope.none), isEmpty);
    expect(
      AiAnswerService.selectedSlides(
        deck,
        1,
        SlideScope.current,
      ).map((s) => s.id),
      ['2'],
    );
    expect(
      AiAnswerService.selectedSlides(
        deck,
        1,
        SlideScope.currentAndNext,
      ).map((s) => s.id),
      ['2', '3'],
    );
    expect(
      AiAnswerService.selectedSlides(
        deck,
        2,
        SlideScope.currentAndNext,
      ).map((s) => s.id),
      ['3'],
    );
    expect(
      AiAnswerService.selectedSlides(deck, 1, SlideScope.all).map((s) => s.id),
      ['1', '2', '3'],
    );
  });
  test('exact user prompt and optional slide sentence', () {
    expect(
      AiAnswerService.prompt(q, false),
      '请使用最简洁的回答完成这道题，不要使用markdown：题目\nA. 甲\nB. 乙\nC. 丙',
    );
    expect(AiAnswerService.prompt(q, true).endsWith(defaultSlidePrompt), true);
  });
  test('custom prompts replace the question token or append the question', () {
    expect(
      AiAnswerService.prompt(q, false, template: '只输出答案：{question}'),
      '只输出答案：${q.promptText}',
    );
    expect(
      AiAnswerService.prompt(q, true, template: '用中文回答'),
      '用中文回答\n${q.promptText}\n$defaultSlidePrompt',
    );
    expect(
      AiAnswerService.prompt(q, false, template: ' '),
      AiAnswerService.prompt(q, false),
    );
  });
  test('slide prompt is appended after the question only for sent slides', () {
    expect(
      AiAnswerService.prompt(
        q,
        true,
        template: '答案：{question}',
        slidePrompt: '请结合讲义中的定义作答',
      ),
      '答案：${q.promptText}\n请结合讲义中的定义作答',
    );
    expect(
      AiAnswerService.prompt(
        q,
        false,
        template: '答案：{question}',
        slidePrompt: '请结合讲义中的定义作答',
      ),
      '答案：${q.promptText}',
    );
    expect(
      AiAnswerService.prompt(q, true, slidePrompt: '  '),
      AiAnswerService.prompt(q, false),
    );
  });

  for (final sendSlides in [false, true]) {
    test('transport uses saved slide prompt sentSlides=$sendSlides', () async {
      final adapter = AiAdapter();
      final service = AiAnswerService(
        client: Dio()..httpClientAdapter = adapter,
      );
      await service.generate(
        settings: AppSettings(
          baseUrl: 'https://ai.example.com/v1',
          model: 'vision',
          slidePrompt: '依据所附课件回答',
        ),
        question: q,
        slides: sendSlides ? [slides.first] : [],
        loadImage: (_) async =>
            Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
      );
      final content = array(
        object(
          array(object(adapter.requests.single.data)['messages']).first,
        )['content'],
      );
      final text = str(object(content.first)['text']);
      expect(text.contains('依据所附课件回答'), sendSlides);
      expect(text.contains(defaultSlidePrompt), false);
    });
  }
  test(
    'model discovery returns explicit unique options using only its key',
    () async {
      final adapter = AiAdapter()
        ..modelsData = {
          'data': [
            {'id': 'first'},
            {'id': 'second'},
            {'id': 'first'},
            {'id': ''},
            {'id': 12},
          ],
        };
      final service = AiAnswerService(
        client: Dio()..httpClientAdapter = adapter,
      );
      expect(
        await service.models(
          baseUrl: 'https://ai.example.com/v1/',
          apiKey: 'secret',
        ),
        ['first', 'second'],
      );
      final request = adapter.requests.single;
      expect(request.uri.toString(), 'https://ai.example.com/v1/models');
      expect(request.headers['Authorization'], 'Bearer secret');
      expect(request.followRedirects, isFalse);
      expect(
        request.headers.keys.any((key) => key.toLowerCase() == 'cookie'),
        isFalse,
      );
    },
  );
  test('model errors hide server bodies and never expose API keys', () async {
    final adapter = AiAdapter()
      ..statusCode = 401
      ..modelsData = {'message': 'key=secret-user-key; echo'};
    final service = AiAnswerService(client: Dio()..httpClientAdapter = adapter);
    await expectLater(
      service.models(
        baseUrl: 'https://ai.example.com/v1',
        apiKey: 'secret-user-key',
      ),
      throwsA(predicate((e) => e.toString() == '模型列表获取失败（HTTP 401）')),
    );
  });
  test(
    'an invalid or empty model list cannot create an implicit selection',
    () async {
      final adapter = AiAdapter()..modelsData = {'data': []};
      final service = AiAnswerService(
        client: Dio()..httpClientAdapter = adapter,
      );
      await expectLater(
        service.models(baseUrl: 'https://ai.example.com/v1', apiKey: 'test'),
        throwsA(isA<ApiFailure>()),
      );
      adapter.modelsData = {'data': 'invalid'};
      await expectLater(
        service.models(baseUrl: 'https://ai.example.com/v1', apiKey: 'test'),
        throwsA(isA<ApiFailure>()),
      );
    },
  );
  test('answer generation requires the model selected in settings', () async {
    final adapter = AiAdapter();
    final service = AiAnswerService(client: Dio()..httpClientAdapter = adapter);
    await expectLater(
      service.generate(
        settings: AppSettings(baseUrl: 'https://ai.example.com/v1'),
        question: q,
        slides: const [],
        loadImage: (_) async => Uint8List(0),
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(adapter.requests, isEmpty);
  });
  test('ambiguous model prose cannot become arbitrary choice selections', () {
    expect(AiAnswerService.parse('A、C', q), ['A', 'C']);
    expect(
      () => AiAnswerService.parse('The answer could be A or C', q),
      throwsA(isA<ApiFailure>()),
    );
    expect(
      () => AiAnswerService.parse(
        'AB',
        const Question(
          id: 'q',
          body: '',
          type: 1,
          options: {'A': 'a', 'B': 'b', 'C': 'c'},
        ),
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(AiAnswerService.parse('甲', q), ['A']);
  });
  for (final type in [1, 2, 3]) {
    test('two-option type $type uses judgment single-choice parsing', () {
      final question = Question(
        id: 'two-$type',
        type: type,
        body: '任意两个选项',
        selectionLimit: 2,
        options: const {'A': '甲', 'B': '乙'},
      );
      expect(question.isJudgment, isTrue);
      expect(question.typeLabel, '判断题');
      expect(AiAnswerService.parse('A', question), ['A']);
      expect(AiAnswerService.parse('乙', question), ['B']);
      expect(
        () => AiAnswerService.parse('AB', question),
        throwsA(isA<ApiFailure>()),
      );
    });
  }
  test('fill blanks enforce count; subjective answers stay structured', () {
    expect(
      AiAnswerService.parse(
        '一\n二',
        const Question(id: 'q', body: '', type: 4, blankCount: 2),
      ),
      ['一', '二'],
    );
    expect(
      () => AiAnswerService.parse(
        '一',
        const Question(id: 'q', body: '', type: 4, blankCount: 2),
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(
      AiAnswerService.parse('简答', const Question(id: 'q', body: '', type: 5)),
      {'content': '简答', 'pics': [], 'videos': []},
    );
  });
  test(
    'type six judgement is a single choice and voting respects its limit',
    () {
      const judgement = Question(
        id: 'j',
        body: '判断题',
        type: 6,
        options: {'A': '正确', 'B': '错误'},
      );
      expect(AiAnswerService.parse('A', judgement), ['A']);
      expect(
        () => AiAnswerService.parse('AB', judgement),
        throwsA(isA<ApiFailure>()),
      );
      const vote = Question(
        id: 'v',
        body: '投票',
        type: 3,
        selectionLimit: 2,
        options: {'A': '甲', 'B': '乙', 'C': '丙'},
      );
      expect(AiAnswerService.parse('AB', vote), ['A', 'B']);
      expect(
        () => AiAnswerService.parse('ABC', vote),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        Question.fromJson({
          'problemId': 'v',
          'problemType': 3,
          'pollingCount': 2,
        }).selectionLimit,
        2,
      );
      expect(vote.launched(1, 60).selectionLimit, 2);
    },
  );
  test(
    'AI transport carries only its key and embeds actual slide image bytes',
    () async {
      final adapter = AiAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final result = await AiAnswerService(client: dio).generate(
        settings: AppSettings(
          baseUrl: 'https://ai.example.com/v1/',
          apiKey: 'test-ai-key',
          model: 'vision-test',
          customPrompt: '简洁作答：{question}',
        ),
        question: q,
        slides: [slides.first],
        loadImage: (_) async =>
            Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
      );
      expect(result, 'A');
      expect(adapter.requests.length, 1);
      final request = adapter.requests.last;
      expect(
        request.uri.toString(),
        'https://ai.example.com/v1/chat/completions',
      );
      expect(request.headers['Authorization'], 'Bearer test-ai-key');
      expect(
        request.headers.keys.any((key) => key.toLowerCase() == 'cookie'),
        false,
      );
      expect(object(request.data)['model'], 'vision-test');
      final content = array(
        object(array(object(request.data)['messages']).first)['content'],
      );
      expect(
        object(content.first)['text'],
        '简洁作答：${q.promptText}\n$defaultSlidePrompt',
      );
      expect(
        object(object(content[1])['image_url'])['url'],
        startsWith('data:image/png;base64,'),
      );
    },
  );
}
