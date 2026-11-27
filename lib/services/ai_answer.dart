import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;
import '../domain/models.dart';
import 'ai_request_scheduler.dart';

class AiAnswerService {
  final Dio _client;
  AiAnswerService({Dio? client})
    : _client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 90),
              sendTimeout: const Duration(seconds: 60),
            ),
          );

  static Uri endpoint(String baseUrl, String resource) {
    var uri = Uri.tryParse(baseUrl.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ApiFailure('请填写有效的 AI base_url，例如 https://example.com/v1');
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    path = path.replaceFirst(RegExp(r'/(chat/completions|models)$'), '');
    if (path.isEmpty) path = '/v1';
    uri = uri.replace(path: '$path/$resource');
    return uri;
  }

  static List<Slide> selectedSlides(
    Presentation? deck,
    int index,
    SlideScope scope,
  ) {
    if (scope == SlideScope.none) return const [];
    if (deck == null || deck.slides.isEmpty) {
      throw const ApiFailure('课件尚未加载，未调用 AI');
    }
    if (scope == SlideScope.all) return List.of(deck.slides);
    if (index < 0 || index >= deck.slides.length) {
      throw const ApiFailure('当前课件页无效，未调用 AI');
    }
    return deck.slides.sublist(
      index,
      scope == SlideScope.currentAndNext
          ? (index + 2).clamp(0, deck.slides.length)
          : index + 1,
    );
  }

  static String prompt(
    Question question,
    bool slides, {
    String template = defaultAiPrompt,
    String slidePrompt = defaultSlidePrompt,
  }) {
    final configured = template.trim().isEmpty ? defaultAiPrompt : template;
    final text = configured.contains('{question}')
        ? configured.replaceAll('{question}', question.promptText)
        : '$configured\n${question.promptText}';
    final extra = slidePrompt.trim();
    return '$text${slides && extra.isNotEmpty ? '\n$extra' : ''}';
  }

  Future<List<String>> models({
    required String baseUrl,
    required String apiKey,
  }) async {
    try {
      final response = await _client.getUri(
        endpoint(baseUrl, 'models'),
        options: Options(headers: _headers(apiKey), followRedirects: false),
      );
      final data = object(response.data)['data'];
      if (data is! List) throw const ApiFailure('AI 未返回有效的模型列表');
      final ids = <String>{};
      for (final item in data) {
        final id = object(item)['id'];
        if (id is String && id.trim().isNotEmpty) ids.add(id.trim());
      }
      if (ids.isEmpty) throw const ApiFailure('AI 没有返回可选择的模型');
      return List.unmodifiable(ids);
    } on DioException catch (error) {
      throw _requestFailure('模型列表获取失败', error);
    }
  }

  static Map<String, String> _headers(String apiKey) => {
    'Content-Type': 'application/json',
    if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
  };

  static ApiFailure _requestFailure(String message, DioException error) {
    final code = error.response?.statusCode;
    if (code == 429) {
      return AiRateLimitFailure(
        '$message：请求过于频繁或额度不足（HTTP 429）',
        retryAfter: AiRateLimitFailure.parseRetryAfter(
          error.response?.headers.value('retry-after'),
        ),
      );
    }
    final reason = code != null
        ? switch (code) {
            401 => '认证失败，请检查 API key',
            403 => '访问被拒绝，请检查模型权限',
            429 => '请求过于频繁或额度不足',
            >= 500 => '模型服务暂时不可用',
            _ => '服务返回错误',
          }
        : switch (error.type) {
            DioExceptionType.connectionTimeout => '连接超时',
            DioExceptionType.receiveTimeout => '等待模型响应超时',
            DioExceptionType.sendTimeout => '发送请求超时',
            DioExceptionType.connectionError => '网络连接失败',
            DioExceptionType.badCertificate => '服务器证书校验失败',
            DioExceptionType.cancel => '请求已取消',
            _ => '网络请求失败，请检查地址和网络',
          };
    return ApiFailure(
      '$message：$reason${code == null ? '' : '（HTTP $code）'}',
      code,
    );
  }

  Future<String> generate({
    required AppSettings settings,
    required Question question,
    required List<Slide> slides,
    required Future<Uint8List> Function(String url) loadImage,
  }) async {
    final headers = _headers(settings.apiKey);
    final model = settings.model.trim();
    if (model.isEmpty) {
      throw const ApiFailure('请先在设置中获取并选择模型');
    }
    try {
      final content = <Json>[
        {
          'type': 'text',
          'text': prompt(
            question,
            slides.isNotEmpty,
            template: settings.customPrompt,
            slidePrompt: settings.slidePrompt,
          ),
        },
      ];
      var totalBytes = 0;
      final attached = <String>{};
      Future<void> attach(String url) async {
        if (AiRequestScheduler.currentCancellationToken?.isCancelled == true) {
          throw const AiGenerationCanceled();
        }
        if (!attached.add(url)) return;
        final Uint8List bytes;
        if (url.startsWith('data:')) {
          try {
            bytes = UriData.parse(url).contentAsBytes();
          } on FormatException {
            throw const ApiFailure('题目附图数据无效，未调用 AI');
          }
        } else {
          bytes = await loadImage(url.startsWith('//') ? 'https:$url' : url);
        }
        totalBytes += bytes.length;
        if (totalBytes > 40 * 1024 * 1024) {
          throw const ApiFailure('题目和课件图片超过 40 MB，请减少发送页数；本次未调用 AI');
        }
        content.add({
          'type': 'image_url',
          'image_url': {
            'url': 'data:${_mimeType(bytes)};base64,${base64Encode(bytes)}',
          },
        });
      }

      // Question figures are always part of the question. The slide scope only
      // controls the optional teaching material, never the question itself.
      for (final image
          in html.parseFragment(question.promptText).querySelectorAll('img')) {
        final source = image.attributes['src'] ?? '';
        if (source.isEmpty) throw const ApiFailure('题目附图缺少地址，未调用 AI');
        await attach(source);
      }
      for (final slide in slides) {
        if (slide.imageUrl.isEmpty) {
          throw const ApiFailure('所选课件包含缺失的图片，未调用 AI');
        }
        await attach(slide.imageUrl);
      }
      if (AiRequestScheduler.currentCancellationToken?.isCancelled == true) {
        throw const AiGenerationCanceled();
      }
      final response = await AiRequestScheduler.trackTransport(
        _client.postUri(
          endpoint(settings.baseUrl, 'chat/completions'),
          data: {
            'model': model,
            'messages': [
              {'role': 'user', 'content': content},
            ],
            'stream': false,
          },
          options: Options(headers: headers, followRedirects: false),
          cancelToken: AiRequestScheduler.currentCancellationToken,
        ),
      );
      final choices = array(object(response.data)['choices']);
      if (choices.isEmpty) throw const ApiFailure('AI 没有返回答案');
      final value = object(object(choices.first)['message'])['content'];
      final answer = value is String
          ? value.trim()
          : array(
              value,
            ).map((item) => str(object(item)['text'])).join('\n').trim();
      if (answer.isEmpty) throw const ApiFailure('AI 返回了空答案');
      return answer;
    } on DioException catch (error) {
      // Server bodies can echo prompts or authorization; do not expose them.
      throw _requestFailure('AI 请求失败', error);
    }
  }

  static String _mimeType(Uint8List bytes) {
    if (bytes.length >= 8 && bytes[0] == 137 && bytes[1] == 80) {
      return 'image/png';
    }
    if (bytes.length >= 3 && bytes[0] == 255 && bytes[1] == 216) {
      return 'image/jpeg';
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF') {
      return 'image/webp';
    }
    throw const ApiFailure('课件图片格式不受 AI 图像接口支持');
  }

  static String plainText(String value) => value
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .trim();

  static dynamic parse(String raw, Question question) {
    var value = raw
        .trim()
        .replaceAll(RegExp(r'^```(?:json|text)?\s*|\s*```$'), '')
        .trim();
    if (value.isEmpty) throw const ApiFailure('答案内容为空');
    if (question.type >= 1 && question.type <= 3 || question.isJudgment) {
      final keys = question.options.keys.toList();
      if (keys.isEmpty) throw const ApiFailure('题目选项尚未加载，未自动提交');
      final normalized = value.toUpperCase().replaceFirst(
        RegExp(r'^(答案|选项|ANSWER)\s*[:：]?\s*'),
        '',
      );
      final matched = keys
          .where(
            (key) =>
                normalized == key.toUpperCase() ||
                plainText(value) == plainText(question.options[key]!),
          )
          .toList();
      if (matched.length == 1) return matched;
      final tokens = normalized.replaceAll(RegExp(r'[\s,，、;；\[\]"\x27。.]'), '');
      final combined = keys
          .where((key) => tokens.contains(key.toUpperCase()))
          .toList();
      final remainder = combined.fold(
        tokens,
        (String rest, String key) => rest.replaceAll(key.toUpperCase(), ''),
      );
      if (combined.isEmpty ||
          remainder.isNotEmpty ||
          ((question.type == 1 || question.isJudgment) &&
              combined.length != 1) ||
          (question.type == 3 && combined.length > question.selectionLimit)) {
        throw const ApiFailure('答案无法明确匹配选项，未自动提交');
      }
      return combined;
    }
    if (question.type == 4) {
      List<String> blanks;
      try {
        blanks = array(jsonDecode(value)).map(str).toList();
      } on FormatException {
        blanks = [];
      }
      if (blanks.isEmpty) {
        blanks = value
            .split(RegExp(r'\r?\n|[;；]'))
            .map((e) => e.trim())
            .toList();
      }
      if (blanks.length != question.blankCount ||
          blanks.any((e) => e.isEmpty)) {
        throw ApiFailure('填空答案数量应为 ${question.blankCount}，未自动提交');
      }
      return blanks;
    }
    if (question.type == 5) return {'content': value, 'pics': [], 'videos': []};
    throw const ApiFailure('暂不支持此题型自动答题');
  }
}
