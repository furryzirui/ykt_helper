import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../domain/models.dart';

/// Ordinary Rain Classroom only. Account cookies never leave the official host.
class RainApi {
  static final Uri origin = Uri.parse('https://www.yuketang.cn');
  final Dio dio;
  final CookieJar _cookies = CookieJar();
  final Future<void> Function(String cookies)? onCookiesChanged;
  final void Function(int? status)? onRequestFailure;
  final Map<String, Cookie> _savedCookies = {};
  final Map<String, int> _locationRounds = {};
  final Map<String, Future<bool>> _locationPending = {};
  final Set<String> _locationAccepted = {};
  final Map<String, Set<String>> _historyPages = {};
  String? userId;
  int _epoch = 0;
  Future<void> _cookieWrites = Future<void>.value();
  final String _deviceId = '${DateTime.now().microsecondsSinceEpoch}';

  RainApi({Dio? dio, this.onCookiesChanged, this.onRequestFailure})
    : dio = dio ?? Dio() {
    this.dio.options = BaseOptions(
      baseUrl: origin.toString(),
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 35),
      sendTimeout: const Duration(seconds: 30),
      followRedirects: false,
      headers: {
        'User-Agent': 'ykt_helper/0.1.3 Android',
        'Accept': 'application/json',
        'xtbz': 'ykt',
        'x-client': 'app',
        'buildnumber': '1610',
        'xtua': 'client=app&tag=1.3.3&platform=Android',
      },
    );
    this.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          if (request.uri.scheme != 'https' ||
              request.uri.host != origin.host ||
              request.uri.port != 443) {
            return handler.reject(
              DioException(
                requestOptions: request,
                error: const ApiFailure('雨课堂认证请求地址无效'),
              ),
            );
          }
          request.extra['rainEpoch'] = _epoch;
          final cookies = await _cookies.loadForRequest(request.uri);
          for (final cookie in cookies) {
            if (cookie.name == 'csrftoken') {
              request.headers['x-csrftoken'] = cookie.value;
            }
            if (cookie.name == 'sessionid') {
              request.headers['sessionid'] = cookie.value;
            }
          }
          if (userId != null) request.headers['x-uid'] = userId;
          handler.next(request);
        },
        onResponse: (response, handler) {
          if (response.requestOptions.extra['rainEpoch'] != _epoch) {
            return handler.reject(
              DioException(
                requestOptions: response.requestOptions,
                error: const ApiFailure('登录会话已切换，请重试'),
              ),
            );
          }
          handler.next(response);
        },
      ),
    );
    this.dio.interceptors.add(CookieManager(_cookies));
    this.dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) async {
          final epoch = response.requestOptions.extra['rainEpoch'];
          if (epoch != _epoch) {
            return handler.reject(
              DioException(
                requestOptions: response.requestOptions,
                error: const ApiFailure('登录会话已退出'),
              ),
            );
          }
          for (final value
              in response.headers[HttpHeaders.setCookieHeader] ?? <String>[]) {
            final cookie = Cookie.fromSetCookieValue(value);
            if (_validDomain(cookie)) {
              cookie.path ??= _defaultCookiePath(response.requestOptions.uri);
              if (cookie.maxAge != null) {
                cookie.expires = DateTime.now().add(
                  Duration(seconds: cookie.maxAge!),
                );
                cookie.maxAge = null;
              }
              _savedCookies[_cookieKey(cookie)] = cookie;
            }
          }
          if (response.headers[HttpHeaders.setCookieHeader]?.isNotEmpty ??
              false) {
            try {
              await _persistCookies(await exportCookies(), epoch as int);
            } catch (_) {
              return handler.reject(
                DioException(
                  requestOptions: response.requestOptions,
                  error: const ApiFailure('登录凭证无法安全保存，请重试'),
                ),
              );
            }
          }
          if (epoch != _epoch) {
            return handler.reject(
              DioException(
                requestOptions: response.requestOptions,
                error: const ApiFailure('登录会话已退出'),
              ),
            );
          }
          handler.next(response);
        },
        onError: (error, handler) {
          onRequestFailure?.call(error.response?.statusCode);
          handler.next(error);
        },
      ),
    );
  }

  bool _validDomain(Cookie cookie) {
    final domain = (cookie.domain ?? origin.host).replaceFirst(
      RegExp(r'^\.'),
      '',
    );
    return domain == origin.host || domain == 'yuketang.cn';
  }

  String _cookieKey(Cookie c) =>
      '${c.domain ?? origin.host}|${c.path ?? '/'}|${c.name}';
  String _defaultCookiePath(Uri uri) {
    final end = uri.path.lastIndexOf('/');
    return end <= 0 ? '/' : uri.path.substring(0, end);
  }

  Future<void> _persistCookies(String value, int epoch) {
    final next = _cookieWrites.catchError((Object _) {}).then((_) async {
      if (epoch == _epoch) await onCookiesChanged?.call(value);
    });
    _cookieWrites = next;
    return next;
  }

  bool? _flag(dynamic value) {
    if (value == true || value == 1 || value == '1' || value == 'true') {
      return true;
    }
    if (value == false || value == 0 || value == '0' || value == 'false') {
      return false;
    }
    return null;
  }

  Future<void> restoreCookies(String serialized) async {
    _epoch++;
    userId = null;
    await _cookies.deleteAll();
    _savedCookies.clear();
    final values = jsonDecode(serialized);
    if (values is! List) throw const ApiFailure('登录凭证格式无效');
    for (final value in values) {
      final c = Cookie.fromSetCookieValue(str(value));
      if (!_validDomain(c)) throw const ApiFailure('登录凭证包含其他服务的 Cookie');
      _savedCookies[_cookieKey(c)] = c;
      await _cookies.saveFromResponse(origin, [c]);
    }
  }

  Future<String> exportCookies() async => jsonEncode(
    _savedCookies.values
        .where((c) => c.expires == null || c.expires!.isAfter(DateTime.now()))
        .map((c) => c.toString())
        .toList(),
  );

  Future<Response<dynamic>> _request(
    String path, {
    Json? body,
    Json? query,
    ClassroomSession? session,
  }) async {
    if (!path.startsWith('/') || path.startsWith('//')) {
      throw const ApiFailure('接口路径无效');
    }
    if (session != null && (userId == null || session.userId != userId)) {
      throw const ApiFailure('课堂凭证与当前账号不符，请重新进入课堂', 401);
    }
    try {
      final response = await dio.request<dynamic>(
        path,
        data: body,
        queryParameters: query,
        options: Options(
          method: body == null ? 'GET' : 'POST',
          headers: session == null
              ? null
              : {'Authorization': 'Bearer ${session.bearer}'},
        ),
      );
      final json = _json(response.data);
      _success(json);
      return response;
    } on DioException catch (error) {
      if (error.error is ApiFailure) throw error.error as ApiFailure;
      final code = error.response?.statusCode;
      if (code == 401) throw const ApiFailure('登录已失效，请重新登录', 401);
      if (code == 403) throw const ApiFailure('当前账号没有访问此内容的权限', 403);
      if (code != null) throw ApiFailure('雨课堂请求失败（HTTP $code）', code);
      throw const ApiFailure('无法连接雨课堂，请检查网络后重试');
    }
  }

  Json _json(dynamic value) {
    if (value is String) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        throw const ApiFailure('雨课堂返回了无法解析的数据');
      }
    }
    if (value is! Map) throw const ApiFailure('雨课堂返回的数据结构不完整');
    return object(value);
  }

  void _success(Json json) {
    final code = json['code'] ?? json['errcode'];
    if ((code != null && integer(code, -1) != 0) || json['success'] == false) {
      final n = integer(code, -1);
      final message = switch (n) {
        50001 => '二维码已失效，请刷新二维码',
        50070 => '此课堂需要老师的动态签到二维码',
        51203 => '签到二维码已过期，请获取新的二维码',
        _ => firstText([json['msg'], json['message'], '雨课堂操作失败（$n）']),
      };
      throw ApiFailure(message, n);
    }
  }

  Future<Json> _data(
    String path, {
    Json? body,
    Json? query,
    ClassroomSession? session,
  }) async {
    final json = _json(
      (await _request(path, body: body, query: query, session: session)).data,
    );
    if (json['data'] is! Map) throw const ApiFailure('雨课堂未返回完整数据');
    return object(json['data']);
  }

  void _match(Json json, String key, String expected, String name) {
    if (json[key] != null && str(json[key]) != expected) {
      throw ApiFailure('$name与所选内容不一致，已停止显示');
    }
  }

  // The official student log uses new Date(create_time) directly. Numeric
  // values are milliseconds; ISO date strings must retain their date/offset.
  // Do not infer seconds from the magnitude of an otherwise valid number.
  int _activityDate(dynamic value) {
    if (value is num) return value.isFinite ? value.toInt() : 0;
    if (value is! String) return 0;
    return int.tryParse(value) ??
        DateTime.tryParse(value)?.millisecondsSinceEpoch ??
        0;
  }

  Future<Account> profile() async {
    final data = await _data('/v/course_meta/user_info');
    final account = Account.fromJson(object(data['user_profile']));
    if (account.id.isEmpty) throw const ApiFailure('未取得有效用户资料，请重新登录', 401);
    userId = account.id;
    return account;
  }

  Future<Json> createQr() async {
    _epoch++;
    final qr = await _data('/api/v3/user/login/pre-info');
    if (str(qr['token']).isEmpty ||
        firstText([qr['qrImage'], qr['qrContent']]).isEmpty) {
      throw const ApiFailure('雨课堂未返回有效登录二维码');
    }
    return qr;
  }

  Future<bool> pollQr(String token) async {
    if (token.isEmpty) throw const ApiFailure('二维码 token 为空，请刷新二维码');
    await _request('/api/v3/user/login', body: {'token': token});
    return true;
  }

  /// Invalidate any pending authorization response before closing login UI.
  void cancelLogin() {
    _epoch++;
  }

  void cancelQr() => cancelLogin();

  void _proof(String ticket, String rand) {
    if (ticket.isEmpty || rand.isEmpty) throw const ApiFailure('请先完成官方人机验证');
  }

  Future<void> sendSms(String phone, String ticket, String rand) async {
    _proof(ticket, rand);
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      throw const ApiFailure('请输入有效手机号');
    }
    _epoch++;
    await _request(
      '/api/v3/user/code/send',
      body: {'phoneNumber': phone, 'email': '', 'ticket': ticket, 'rand': rand},
    );
  }

  Future<Account> login({
    required String account,
    required String secret,
    required bool sms,
    required String ticket,
    required String rand,
  }) async {
    _proof(ticket, rand);
    if (account.trim().isEmpty || secret.isEmpty) {
      throw const ApiFailure('请填写账号和登录凭证');
    }
    _epoch++;
    final email = account.contains('@');
    if (sms) {
      await _request(
        '/api/v3/user/code/verify',
        body: {'phoneNumber': account, 'email': '', 'code': secret},
      );
    }
    await _request(
      '/api/v3/user/login/app',
      body: {
        'type': sms
            ? 3
            : email
            ? 2
            : 1,
        'phoneNumber': email ? '' : account,
        'email': email ? account : '',
        'password': sms ? '' : secret,
        'code': sms ? secret : '',
        'pushDeviceId': _deviceId,
        'ticket': ticket,
        'rand': rand,
      },
    );
    return profile();
  }

  Course _course(Json row, bool archived) {
    final nested = object(row['course']);
    final classroom = firstText([row['classroom_id'], row['id']]);
    final course = firstText([
      row['course_id'],
      nested['id'],
      nested['course_id'],
    ]);
    if (classroom.isEmpty || course.isEmpty) {
      throw const ApiFailure('课程缺少课程或班级 ID，无法安全关联');
    }
    return Course(
      courseId: course,
      classroomId: classroom,
      name: firstText([nested['name'], row['course_name'], '课程 $course']),
      classroomName: firstText([row['classroom_name'], row['name']]),
      teacher: str(object(row['teacher'])['name']),
      archived: archived,
    );
  }

  Future<List<Course>> courses() async {
    final uid = userId;
    if (uid == null) throw const ApiFailure('请先登录', 401);
    final results = await Future.wait([
      _data('/v2/api/web/courses/list', query: {'identity': 2}),
      _data('/v2/api/web/classroom_archive', query: {'user_id': uid}),
    ]);
    if (results[0]['list'] is! List || results[1]['classrooms'] is! List) {
      throw const ApiFailure('课程或归档课程列表结构不完整，无法确认全部课程');
    }
    final byClassroom = <String, Course>{};
    for (var i = 0; i < results.length; i++) {
      for (final raw in array(results[i][i == 0 ? 'list' : 'classrooms'])) {
        final c = _course(object(raw), i == 1);
        final existing = byClassroom[c.classroomId];
        if (existing != null && existing.courseId != c.courseId) {
          throw const ApiFailure('同一班级返回了不同课程 ID，请刷新后重试');
        }
        byClassroom.putIfAbsent(c.classroomId, () => c);
      }
    }
    return byClassroom.values.toList(growable: false);
  }

  Future<List<Lesson>> liveLessons() async {
    final data = await _data('/api/v3/classroom/on-lesson');
    if (data['onLessonClassrooms'] is! List) {
      throw const ApiFailure('正在上课的课堂列表不完整');
    }
    final lessons = <String, Lesson>{};
    for (final raw in array(data['onLessonClassrooms'])) {
      final row = object(raw);
      final id = str(row['lessonId']);
      var classroomId = str(row['classroomId']);
      var courseId = str(row['courseId']);
      if (id.isEmpty) throw const ApiFailure('正在上课的课堂缺少课堂 ID');
      if (classroomId.isEmpty || courseId.isEmpty) {
        final info = await _report('lesson-info', id);
        if (courseId.isNotEmpty) _match(info, 'courseId', courseId, '实时课堂课程');
        if (classroomId.isNotEmpty) {
          _match(info, 'classroomId', classroomId, '实时课堂班级');
        }
        classroomId = firstText([classroomId, info['classroomId']]);
        courseId = firstText([courseId, info['courseId']]);
      }
      if (classroomId.isEmpty || courseId.isEmpty) {
        throw const ApiFailure('正在上课的课堂与课堂报告均未返回完整关联 ID');
      }
      lessons[id] = Lesson(
        id: id,
        courseId: courseId,
        classroomId: classroomId,
        title: firstText([row['lessonName'], row['courseName'], '课堂 $id']),
        startedAt: integer(row['start']),
        live: true,
      );
    }
    return lessons.values.toList(growable: false);
  }

  Future<LessonPage> lessons(Course course, int page) async {
    if (page < 0) throw const ApiFailure('课堂页码无效');
    final data = await _data(
      '/v2/api/web/logs/learn/${Uri.encodeComponent(course.classroomId)}',
      query: {'actype': 14, 'page': page, 'offset': 20, 'sort': -1},
    );
    if (data['activities'] is! List || !data.containsKey('has_more')) {
      throw const ApiFailure('课堂列表分页数据不完整');
    }
    final rows = array(data['activities']);
    final more = _flag(data['has_more']);
    if (more == null) throw const ApiFailure('课堂分页状态无效');
    if (rows.isEmpty && more) throw const ApiFailure('服务器返回空页但仍标记有下一页，请刷新课堂列表');
    final result = <String, Lesson>{};
    for (final raw in rows) {
      final row = object(raw);
      _match(row, 'classroom_id', course.classroomId, '课堂班级');
      _match(row, 'course_id', course.courseId, '课堂课程');
      if (row['type'] != null &&
          integer(row['type']) != 14 &&
          integer(row['type']) != 3) {
        continue;
      }
      final id = str(row['courseware_id']);
      if (id.isEmpty) throw const ApiFailure('课堂记录缺少课堂 ID');
      result[id] = Lesson(
        id: id,
        courseId: course.courseId,
        classroomId: course.classroomId,
        title: firstText([row['title'], '课堂 $id']),
        startedAt: _activityDate(row['create_time']),
        endedAt: integer(object(row['content'])['end']),
        oldVersion: _flag(row['oldVersion']) == true,
      );
    }
    final fingerprint = result.keys.join(',');
    if (page == 0) _historyPages[course.key] = {};
    final seen = _historyPages.putIfAbsent(course.key, () => {});
    if (page > 0 && fingerprint.isNotEmpty && !seen.add(fingerprint)) {
      throw const ApiFailure('服务器重复返回同一页课堂，已停止加载，请刷新后重试');
    }
    if (page == 0 && fingerprint.isNotEmpty) seen.add(fingerprint);
    return LessonPage(result.values.toList(growable: false), more);
  }

  Future<ClassroomSession> checkin(String lessonId) async {
    if (userId == null || lessonId.isEmpty) throw const ApiFailure('请登录并选择课堂');
    final response = await _request(
      '/api/v3/lesson/checkin',
      body: {'source': 21, 'lessonId': lessonId, 'joinIfNotIn': true},
    );
    final data = object(_json(response.data)['data']);
    _match(data, 'lessonId', lessonId, '签到课堂');
    final bearer = (response.headers.value('set-auth') ?? '').replaceFirst(
      RegExp(r'^Bearer\s+', caseSensitive: false),
      '',
    );
    final token = str(data['lessonToken']);
    if (bearer.isEmpty || token.isEmpty) throw const ApiFailure('签到未返回完整课堂凭证');
    return ClassroomSession(
      userId: userId!,
      lessonId: lessonId,
      bearer: bearer,
      lessonToken: token,
    );
  }

  Future<String> scanClassroom(String url) async {
    final data = await _data('/api/v3/app/scan', body: {'url': url});
    final id = str(data['value']);
    if (id.isEmpty) throw const ApiFailure('二维码未返回有效课堂 ID');
    return id;
  }

  Future<Json> _report(String kind, String lessonId) async {
    final data = await _data(
      '/api/v3/classroom-report/student/$kind',
      query: {
        'lesson_id': lessonId,
        'front_time': DateTime.now().millisecondsSinceEpoch,
      },
    );
    _match(data, 'lessonId', lessonId, '课堂报告');
    return data;
  }

  Future<LessonDetail> detail(Lesson lesson) async {
    if (lesson.oldVersion) {
      return LessonDetail(lesson: lesson);
    }
    // oldVersion is evidenced on lesson-info.data, not the history row.
    // Read it before requesting report parts that use the current protocol.
    final info = await _report('lesson-info', lesson.id);
    if (lesson.courseId.isNotEmpty) {
      _match(info, 'courseId', lesson.courseId, '课堂课程');
    }
    if (lesson.classroomId.isNotEmpty) {
      _match(info, 'classroomId', lesson.classroomId, '课堂班级');
    }
    final courseId = firstText([lesson.courseId, info['courseId']]);
    final classroomId = firstText([lesson.classroomId, info['classroomId']]);
    if (courseId.isEmpty || classroomId.isEmpty) {
      throw const ApiFailure('课堂信息缺少课程或班级 ID，无法确认课堂归属');
    }
    final resolvedLesson = Lesson(
      id: lesson.id,
      courseId: courseId,
      classroomId: classroomId,
      title: firstText([info['lessonName'], lesson.title]),
      startedAt: integer(info['start'], lesson.startedAt),
      endedAt: integer(info['end']),
      live: lesson.live,
      oldVersion: _flag(info['oldVersion']) == true,
    );
    if (resolvedLesson.oldVersion) {
      return LessonDetail(lesson: resolvedLesson);
    }
    final warnings = <String>[];
    Future<Json> optional(Future<Json> future, String label) async {
      try {
        return await future;
      } catch (e) {
        warnings.add('$label：$e');
        return {};
      }
    }

    final results = await Future.wait([
      _report('detail', lesson.id),
      optional(_report('review', lesson.id), '课堂回顾读取失败'),
    ]);
    final details = results[0], review = results[1];
    Map<String, AnswerRecord> answers = {};
    var answersKnown = true;
    String? answerError;
    try {
      answers = await _answers(lesson.id, '', info, details);
    } catch (e) {
      answersKnown = false;
      answerError = str(e);
    }
    return LessonDetail(
      lesson: resolvedLesson,
      teacher: str(info['teacherName']),
      checkinText: _attendanceStatus(details, integer(info['end'])).label,
      presentations: array(details['presentation'])
          .map((raw) {
            final row = object(raw);
            return PresentationRef(
              str(row['presentationId']),
              str(row['title']),
            );
          })
          .where((ref) => ref.id.isNotEmpty)
          .toList(),
      answers: answers,
      answersKnown: answersKnown,
      answerError: answerError,
      reviewSlides: _reviewSlides(review),
      warnings: warnings,
    );
  }

  Future<AttendanceStatus> attendance(Lesson lesson) async {
    final report = await _report('detail', lesson.id);
    if (lesson.courseId.isNotEmpty) {
      _match(report, 'courseId', lesson.courseId, '签到课程');
    }
    if (lesson.classroomId.isNotEmpty) {
      _match(report, 'classroomId', lesson.classroomId, '签到班级');
    }
    return _attendanceStatus(report, lesson.endedAt);
  }

  AttendanceStatus _attendanceStatus(Json report, int endedAt) {
    final record = object(report['detail']);
    final valid = _flag(record['valid']);
    final checkinTime = int.tryParse(str(record['checkInTime']));
    if (valid == null || checkinTime == null || checkinTime < 0) {
      return AttendanceStatus.unknown;
    }
    if (valid && checkinTime > 0) return AttendanceStatus.signed;
    // An ongoing report can lag behind the check-in request. Only a finished
    // lesson with explicit attendance fields can establish an absence.
    if (endedAt > 0 && endedAt <= DateTime.now().millisecondsSinceEpoch) {
      return AttendanceStatus.unsigned;
    }
    return AttendanceStatus.unknown;
  }

  List<Slide> _reviewSlides(Json review) {
    final pages = <String, Json>{};
    for (final raw in array(review['timelineList'])) {
      final row = object(raw);
      if (row['type'] != 'slide') continue;
      final key =
          '${row['presentationId'] ?? row['pres']}:${row['id'] ?? row['sid']}';
      if (!pages.containsKey(key) ||
          integer(row['dt']) >= integer(pages[key]!['dt'])) {
        pages[key] = row;
      }
    }
    return pages.values
        .where((row) => _flag(row['visible']) == true)
        .map((row) => _slide(row, const {}))
        .toList();
  }

  Slide _slide(Json json, Map<String, AnswerRecord> answers) {
    final rawQuestion = object(json['problem']);
    final question = rawQuestion.isEmpty
        ? null
        : Question.fromJson(rawQuestion);
    return Slide(
      id: firstText([json['id'], json['sid']]),
      index: integer(json['index'] ?? json['si']),
      imageUrl: firstText([json['cover'], json['coverAlt']]),
      text: [
        str(json['note']),
        ...array(json['shapes']).map((s) => str(object(s)['Text'])),
      ].where((s) => s.isNotEmpty).join('\n'),
      question: question,
      ownAnswer: question == null ? null : answers[question.id],
    );
  }

  Future<Presentation> presentation(
    String lessonId,
    String presentationId, {
    ClassroomSession? session,
    bool withAnswers = true,
  }) async {
    if (session != null && session.lessonId != lessonId) {
      throw const ApiFailure('课件与课堂凭证不匹配');
    }
    final data = session == null
        ? await _data(
            '/api/v3/classroom-report/student/ppt',
            query: {'lesson_id': lessonId, 'presentationId': presentationId},
          )
        : await _data(
            '/api/v3/lesson/presentation/fetch',
            query: {'presentation_id': presentationId},
            session: session,
          );
    _match(data, 'lessonId', lessonId, '课件课堂');
    _match(data, 'presentationId', presentationId, '课件');
    _match(data, 'id', presentationId, '课件');
    final rawSlides = data[session == null ? 'slideList' : 'slides'];
    if (rawSlides is! List) throw const ApiFailure('课件没有返回页面列表');
    var answersKnown = false;
    String? answerError;
    Map<String, AnswerRecord> answers = {};
    if (withAnswers) {
      try {
        answers = await ownAnswers(lessonId, presentationId);
        answersKnown = true;
      } catch (e) {
        answerError = str(e);
      }
    }
    final slides = rawSlides
        .map(object)
        .where((row) => session != null || _flag(row['visible']) == true)
        .map((row) => _slide(row, answers))
        .toList(growable: false);
    return Presentation(
      id: presentationId,
      title: str(data['title']),
      slides: slides,
      answersKnown: answersKnown,
      answerError: answerError,
    );
  }

  Future<Map<String, AnswerRecord>> ownAnswers(
    String lessonId,
    String presentationId,
  ) async {
    Object? summaryFailure;
    Json? summary;
    if (presentationId.isNotEmpty) {
      try {
        summary = await _data(
          '/api/v3/lesson-summary/student/presentation',
          query: {'lesson_id': lessonId, 'presentation_id': presentationId},
        );
      } catch (failure) {
        summaryFailure = failure;
      }
    }
    // A malformed successful summary is unknown, rather than an empty report
    // overriding evidence that the server did not provide personal status.
    if (summary != null) {
      return _summaryAnswers(summary, lessonId, presentationId);
    }
    try {
      final results = await Future.wait([
        _report('lesson-info', lessonId),
        _report('detail', lessonId),
      ]);
      return await _answers(lessonId, presentationId, results[0], results[1]);
    } catch (failure) {
      if (summaryFailure != null) {
        throw ApiFailure('本人答题状态未知：$summaryFailure；课堂报告：$failure');
      }
      rethrow;
    }
  }

  Map<String, AnswerRecord> _summaryAnswers(
    Json data,
    String lessonId,
    String presentationId,
  ) {
    if (data['slides'] is! List || data['presentation'] is! Map) {
      throw const ApiFailure('本人答题摘要没有返回完整课件页面，当前状态未知');
    }
    _match(data, 'lessonId', lessonId, '答题摘要课堂');
    _match(object(data['presentation']), 'id', presentationId, '答题摘要课件');
    final answers = <String, AnswerRecord>{};
    for (final value in array(data['slides'])) {
      final slide = object(value);
      if (slide['problem'] == null) continue;
      final problem = object(slide['problem']);
      final id = str(problem['problemId']);
      if (id.isEmpty) {
        throw const ApiFailure('答题摘要题目缺少 ID，当前状态未知');
      }
      // The official playback client treats no result or score:null as not
      // completed. Zero and -1 (awaiting grading) are both completed results.
      if (slide['result'] == null) continue;
      if (slide['result'] is! Map) {
        throw const ApiFailure('本人答题摘要格式无效，当前状态未知');
      }
      final result = object(slide['result']);
      if (!result.containsKey('score')) {
        throw const ApiFailure('本人答题摘要缺少完成状态，当前状态未知');
      }
      final score = result['score'];
      if (score == null) continue;
      if (score is! num || !score.isFinite || result['answer'] == null) {
        throw const ApiFailure('已完成题目未返回完整本人答案，当前状态未知');
      }
      answers[id] = AnswerRecord(
        problemId: id,
        answer: result['answer'],
        source: AnswerSource.server,
        score: score > 0 ? score / 100 : score,
      );
    }
    return answers;
  }

  Future<Map<String, AnswerRecord>> _answers(
    String lessonId,
    String presentationId,
    Json info,
    Json details,
  ) async {
    final raw = object(details['problem'])['studentList'];
    if (raw is! List) throw const ApiFailure('服务端未返回本人答题状态，当前状态未知');
    final result = <String, AnswerRecord>{};
    for (final value in raw) {
      final row = object(value);
      final id = str(row['problemId']);
      if (id.isEmpty || _flag(row['isAnswered']) == null) {
        throw const ApiFailure('本人答题状态缺少必要字段，当前状态未知');
      }
      if (presentationId.isNotEmpty &&
          row['presentationId'] != null &&
          str(row['presentationId']) != presentationId) {
        continue;
      }
      if (_flag(row['isAnswered']) != true) continue;
      dynamic answer = row['result'];
      num? score = row['problemscore'] is num
          ? row['problemscore'] as num
          : null;
      if (answer == null || integer(row['problem_type']) == 5) {
        final identityId = str(info['identityId']);
        if (identityId.isEmpty) {
          throw const ApiFailure('课堂未返回本人的身份 ID，无法读取已提交答案');
        }
        final full = await _data(
          '/api/v3/classroom-report/problem/student-answer',
          query: {
            'lesson_id': lessonId,
            'identityId': identityId,
            'problemId': id,
          },
        );
        final personal = object(full['problem']);
        _match(personal, 'problemId', id, '本人答案');
        _match(object(full['content']), 'problemId', id, '题目');
        answer = personal['result'];
        if (answer == null) throw const ApiFailure('已作答题目未返回本人答案，当前答案未知');
        final rawScore = personal['score'];
        score = rawScore is num
            ? (rawScore > 0 ? rawScore / 100 : rawScore)
            : null;
      }
      result[id] = AnswerRecord(
        problemId: id,
        answer: answer,
        source: AnswerSource.server,
        score: score,
      );
    }
    return result;
  }

  Future<void> submit(
    ClassroomSession session,
    Question question,
    dynamic answer,
  ) async {
    if (question.id.isEmpty) throw const ApiFailure('题目 ID 为空，不能提交');
    if (question.type < 1 || question.type > 6) {
      throw const ApiFailure('暂不支持此题型');
    }
    if (question.type == 5) {
      if (answer is! Map) {
        answer = {'content': str(answer), 'pics': [], 'videos': []};
      }
    } else if (answer is! List) {
      throw const ApiFailure('此题型需要按选项或填空列表提交');
    }
    await _request(
      '/api/v3/lesson/problem/answer',
      session: session,
      body: {
        'problemId': question.id,
        'problemType': question.type,
        'dt': DateTime.now().millisecondsSinceEpoch,
        'result': answer,
      },
    );
  }

  void locationRoundChanged(String lessonId) {
    _locationRounds.update(lessonId, (v) => v + 1, ifAbsent: () => 1);
    _locationAccepted.removeWhere((key) => key.startsWith('$lessonId|'));
  }

  double? _coordinate(dynamic value, double max) {
    if (value is! num && value is! String) return null;
    final n = double.tryParse(str(value));
    return n != null && n.isFinite && n.abs() <= max ? n : null;
  }

  Future<LocationCheckin> locationStatus(ClassroomSession session) async {
    final response = _json(
      (await _request(
        '/api/v3/lesson/location-checkin/eligibility',
        session: session,
      )).data,
    );
    final data = response['data'] is Map ? object(response['data']) : response;
    _match(data, 'lessonId', session.lessonId, '位置签到课堂');
    final target = object(data['session']);
    double? lat = _coordinate(target['centerLat'], 90),
        lng = _coordinate(target['centerLng'], 180);
    if (lat == null || lng == null) {
      lat = _coordinate(data['lat'], 90);
      lng = _coordinate(data['lng'], 180);
    }
    if (_flag(data['signed']) == null ||
        _flag(data['needLocationSignIn']) == null) {
      throw const ApiFailure('服务端未返回完整位置签到状态');
    }
    return LocationCheckin(
      signed: _flag(data['signed']) == true,
      available:
          _flag(data['needLocationSignIn']) == true &&
          lat != null &&
          lng != null,
      latitude: lat,
      longitude: lng,
      address: firstText([data['address'], target['address']]),
      roundId:
          '${_locationRounds[session.lessonId] ?? 0}:${target['id'] ?? data['sessionId'] ?? ''}',
    );
  }

  Future<bool> locationSubmit(
    ClassroomSession session,
    LocationCheckin confirmed,
  ) {
    final key = '${session.lessonId}|${confirmed.fingerprint}';
    return _locationPending.putIfAbsent(key, () async {
      try {
        final fresh = await locationStatus(session);
        if (fresh.signed) return true;
        if (!fresh.available || fresh.fingerprint != confirmed.fingerprint) {
          throw const ApiFailure('位置签到已结束或轮次已变化，请重新查询确认');
        }
        if (!_locationAccepted.contains(key)) {
          await _request(
            '/api/v3/lesson/location-checkin/submit',
            session: session,
            body: {
              'lat': fresh.latitude,
              'lng': fresh.longitude,
              'lessonId': session.lessonId,
              'source': 54,
              'address': fresh.address,
            },
          );
          _locationAccepted.add(key);
        }
        return (await locationStatus(session)).signed;
      } finally {
        _locationPending.remove(key);
      }
    });
  }

  Future<Json> uploadImage(ClassroomSession session, String filePath) async {
    if (session.userId != userId) throw const ApiFailure('账号已切换');
    final token = await _data(
      '/pc/generate_qiniu_token',
      body: {'bucket_name': 'cms-attachment', 'expired_time': 3600},
    );
    if (str(token['token']).isEmpty) throw const ApiFailure('未取得图片上传凭证');
    final name = filePath.replaceAll('\\', '/').split('/').last;
    final key = '${DateTime.now().microsecondsSinceEpoch}$name';
    // This client deliberately has no account interceptors, cookies or Bearer.
    final upload = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 90),
        receiveTimeout: const Duration(seconds: 30),
        followRedirects: false,
      ),
    );
    try {
      final response = await upload.post<dynamic>(
        'https://upload.qiniup.com/',
        data: FormData.fromMap({
          'file': await MultipartFile.fromFile(filePath, filename: key),
          'token': token['token'],
          'key': key,
          'fname': name,
        }),
      );
      final data = _json(response.data);
      if (data['success'] == false || str(data['key']).isEmpty) {
        throw const ApiFailure('图片上传失败');
      }
      if (session.userId != userId) throw const ApiFailure('账号已切换，图片未用于答题');
      final url =
          'https://qn-scd1.yuketang.cn/${str(data['key']).split('/').map(Uri.encodeComponent).join('/')}';
      return {'pic': url, 'thumb': '$url?imageView2/2/w/568'};
    } on DioException {
      throw const ApiFailure('图片上传失败，请重试');
    } finally {
      upload.close();
    }
  }

  Future<void> logout() async {
    _epoch++;
    userId = null;
    _savedCookies.clear();
    _historyPages.clear();
    _locationRounds.clear();
    _locationAccepted.clear();
    await _cookies.deleteAll();
    await _persistCookies('[]', _epoch);
  }
}
