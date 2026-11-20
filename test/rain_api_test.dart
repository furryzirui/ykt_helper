import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/data/rain_api.dart';
import 'package:ykt_helper/domain/models.dart';

class FakeTransport implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final List<RequestOptions> requests = [];
  FakeTransport(this.respond);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody reply(
  dynamic data, {
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  jsonEncode(data),
  200,
  headers: {
    'content-type': ['application/json'],
    ...headers,
  },
);
ResponseBody ok(dynamic data) => reply({'code': 0, 'data': data});
RainApi client(
  FakeTransport transport, {
  Future<void> Function(String)? changed,
}) {
  final dio = Dio()..httpClientAdapter = transport;
  return RainApi(dio: dio, onCookiesChanged: changed)..userId = 'u';
}

const course = Course(courseId: 'c', classroomId: 'r', name: '课程');
const session = ClassroomSession(
  userId: 'u',
  lessonId: 'l',
  bearer: 'http',
  lessonToken: 'ws',
);

void main() {
  test(
    'request diagnostics preserve timeout stage without request secrets',
    () async {
      final diagnostics =
          <({String path, String method, Object error, Duration elapsed})>[];
      final transport = FakeTransport(
        (r) => throw DioException(
          requestOptions: r,
          type: DioExceptionType.receiveTimeout,
          message: 'sensitive response body',
        ),
      );
      final api = RainApi(
        dio: Dio()..httpClientAdapter = transport,
        onRequestError: (path, method, error, elapsed) => diagnostics.add((
          path: path,
          method: method,
          error: error,
          elapsed: elapsed,
        )),
      )..userId = 'u';
      await expectLater(
        api.ownAnswers('l', 'deck', session: session),
        throwsA(predicate((error) => error.toString().contains('等待雨课堂响应超时'))),
      );
      expect(diagnostics, hasLength(1));
      expect(diagnostics.single.path, '/api/v3/lesson/presentation/fetch');
      expect(diagnostics.single.method, 'GET');
      expect(diagnostics.single.error.toString(), isNot(contains('sensitive')));
    },
  );

  test(
    'attendance reads explicit report fields and never infers from entry',
    () async {
      var response = <String, dynamic>{'lessonId': 'l'};
      final transport = FakeTransport((r) {
        expect(r.uri.path, '/api/v3/classroom-report/student/detail');
        expect(r.queryParameters['lesson_id'], 'l');
        return ok(response);
      });
      final api = client(transport);
      const live = Lesson(
        id: 'l',
        courseId: 'c',
        classroomId: 'r',
        title: '课堂',
        live: true,
      );
      expect(await api.attendance(live), AttendanceStatus.unknown);
      response['detail'] = {'valid': 1, 'checkInTime': 1767225687630};
      expect(await api.attendance(live), AttendanceStatus.signed);
      response['detail'] = {'valid': 0, 'checkInTime': 0};
      expect(await api.attendance(live), AttendanceStatus.unknown);
      const ended = Lesson(
        id: 'l',
        courseId: 'c',
        classroomId: 'r',
        title: '课堂',
        endedAt: 1,
      );
      expect(await api.attendance(ended), AttendanceStatus.unsigned);
      response['detail'] = {'valid': 0};
      expect(await api.attendance(ended), AttendanceStatus.unknown);
      response['lessonId'] = 'other';
      await expectLater(api.attendance(live), throwsA(isA<ApiFailure>()));
    },
  );
  test(
    'history detail no longer requests replay or retains playback state',
    () async {
      final transport = FakeTransport((r) {
        expect(r.uri.path, isNot(contains('/replay')));
        if (r.uri.path.endsWith('/lesson-info')) {
          return ok({'lessonId': 'l', 'courseId': 'c', 'classroomId': 'r'});
        }
        if (r.uri.path.endsWith('/detail')) {
          return ok({
            'lessonId': 'l',
            'detail': {'valid': 1, 'checkInTime': 1},
            'problem': {'studentList': []},
          });
        }
        return ok({'lessonId': 'l', 'timelineList': []});
      });
      final detail = await client(transport).detail(
        const Lesson(id: 'l', courseId: 'c', classroomId: 'r', title: '课堂'),
      );
      expect(detail.checkinText, '已签到');
      expect(detail.warnings, isEmpty);
      expect(
        transport.requests.map((r) => r.uri.path),
        isNot(contains('/api/v3/classroom-report/replay')),
      );
    },
  );
  test(
    'course list keeps separate classrooms and includes archived courses',
    () async {
      final transport = FakeTransport(
        (r) => r.uri.path.endsWith('/courses/list')
            ? reply({
                'errcode': 0,
                'data': {
                  'list': [
                    {
                      'classroom_id': 'r1',
                      'name': '一班',
                      'course': {'id': '9007199254740993', 'name': '数学'},
                    },
                    {
                      'classroom_id': 'r2',
                      'name': '二班',
                      'course': {'id': '9007199254740993', 'name': '数学'},
                    },
                  ],
                },
              })
            : reply({
                'errcode': 0,
                'data': {
                  'classrooms': [
                    {
                      'id': 'r3',
                      'name': '旧班级',
                      'course': {'id': 'old', 'name': '历史课程'},
                    },
                  ],
                },
              }),
      );
      final result = await client(transport).courses();
      expect(result.map((c) => c.classroomId), ['r1', 'r2', 'r3']);
      expect(result.first.courseId, '9007199254740993');
      expect(result.last.archived, isTrue);
      expect(transport.requests.first.queryParameters['identity'], 2);
    },
  );

  test(
    'archive errors do not masquerade as a complete course catalog',
    () async {
      final api = client(
        FakeTransport(
          (r) => r.uri.path.endsWith('/courses/list')
              ? reply({
                  'errcode': 0,
                  'data': {'list': []},
                })
              : reply({'errcode': 42, 'msg': '归档读取失败'}),
        ),
      );
      await expectLater(api.courses(), throwsA(isA<ApiFailure>()));
    },
  );

  test(
    'classroom pagination uses page zero and detects a repeated page',
    () async {
      final transport = FakeTransport(
        (r) => reply({
          'errcode': 0,
          'data': {
            'activities': [
              {'type': 14, 'courseware_id': 'l', 'title': '第一课'},
            ],
            'has_more': true,
          },
        }),
      );
      final api = client(transport);
      expect((await api.lessons(course, 0)).lessons.single.id, 'l');
      await expectLater(api.lessons(course, 1), throwsA(isA<ApiFailure>()));
      expect(transport.requests.first.uri.path, '/v2/api/web/logs/learn/r');
      expect(transport.requests.first.queryParameters, {
        'actype': 14,
        'page': 0,
        'offset': 20,
        'sort': -1,
      });
    },
  );

  test('mismatched classroom records are refused', () async {
    final api = client(
      FakeTransport(
        (r) => ok({
          'activities': [
            {'type': 14, 'courseware_id': 'l', 'classroom_id': 'wrong'},
          ],
          'has_more': false,
        }),
      ),
    );
    await expectLater(api.lessons(course, 0), throwsA(isA<ApiFailure>()));
  });

  test('official legacy classroom rows are retained', () async {
    final api = client(
      FakeTransport(
        (r) => ok({
          'activities': [
            {'type': 3, 'courseware_id': 'old-lesson', 'title': '旧课堂'},
          ],
          'has_more': false,
        }),
      ),
    );
    final lesson = (await api.lessons(course, 0)).lessons.single;
    expect(lesson.id, 'old-lesson');
    expect(lesson.oldVersion, isFalse);
  });

  test('explicit oldVersion metadata stops newer report requests', () async {
    final transport = FakeTransport((r) {
      expect(r.uri.path, '/api/v3/classroom-report/student/lesson-info');
      return ok({
        'lessonId': 'legacy',
        'courseId': 'c',
        'classroomId': 'r',
        'lessonName': '旧版课堂记录',
        'oldVersion': true,
      });
    });
    final api = client(transport);
    final detail = await api.detail(
      const Lesson(id: 'legacy', courseId: 'c', classroomId: 'r', title: '课堂'),
    );
    expect(detail.lesson.oldVersion, isTrue);
    expect(detail.lesson.title, '旧版课堂记录');
    expect(detail.presentations, isEmpty);
    expect(detail.answersKnown, isFalse);
    expect(transport.requests, hasLength(1));
    await api.detail(detail.lesson);
    expect(transport.requests, hasLength(1));
  });

  test(
    'history date follows official Date milliseconds and ISO offsets',
    () async {
      final api = client(
        FakeTransport(
          (r) => ok({
            'activities': [
              {'type': 14, 'courseware_id': 'ms', 'create_time': 1767225600123},
              {
                'type': 14,
                'courseware_id': 'iso',
                'create_time': '2026-01-01T08:00:00.123+08:00',
              },
              {
                'type': 14,
                'courseware_id': 'invalid',
                'create_time': 'invalid',
              },
            ],
            'has_more': false,
          }),
        ),
      );
      final result = (await api.lessons(course, 0)).lessons;
      expect(result[0].startedAt, 1767225600123);
      expect(result[1].startedAt, result[0].startedAt);
      expect(result[2].startedAt, 0);
      expect(
        DateTime.fromMillisecondsSinceEpoch(result[0].startedAt).year,
        2026,
      );
    },
  );

  test(
    'live classroom missing association resolves only from lesson metadata',
    () async {
      final api = client(
        FakeTransport(
          (r) => r.uri.path.endsWith('/on-lesson')
              ? ok({
                  'onLessonClassrooms': [
                    {'lessonId': 'l', 'courseId': 'c'},
                  ],
                })
              : ok({'lessonId': 'l', 'courseId': 'c', 'classroomId': 'r'}),
        ),
      );
      final result = await api.liveLessons();
      expect(result.single.courseId, 'c');
      expect(result.single.classroomId, 'r');
    },
  );

  test('scanned lesson metadata fills empty associations', () async {
    final api = client(
      FakeTransport((r) {
        if (r.uri.path.endsWith('/lesson-info')) {
          return ok({
            'lessonId': 'l',
            'courseId': 'c',
            'classroomId': 'r',
            'lessonName': '正式课堂',
          });
        }
        return ok({
          'lessonId': 'l',
          'problem': {'studentList': []},
        });
      }),
    );
    final result = await api.detail(
      const Lesson(
        id: 'l',
        courseId: '',
        classroomId: '',
        title: '课堂',
        live: true,
      ),
    );
    expect(result.lesson.courseId, 'c');
    expect(result.lesson.classroomId, 'r');
    expect(result.lesson.title, '正式课堂');
    expect(result.lesson.live, isTrue);
  });

  test('known lesson associations still reject mismatched metadata', () async {
    final api = client(
      FakeTransport(
        (r) => ok({'lessonId': 'l', 'courseId': 'wrong', 'classroomId': 'r'}),
      ),
    );
    await expectLater(
      api.detail(
        const Lesson(id: 'l', courseId: 'c', classroomId: 'r', title: '课堂'),
      ),
      throwsA(isA<ApiFailure>()),
    );
  });

  test('personal result is used instead of the correct answer', () async {
    final transport = FakeTransport((r) {
      if (r.uri.path.endsWith('/lesson-summary/student/presentation')) {
        return reply({'code': 404, 'msg': 'summary unavailable'});
      }
      if (r.uri.path.endsWith('/lesson-info')) {
        return ok({'lessonId': 'l', 'identityId': 'identity'});
      }
      if (r.uri.path.endsWith('/student/detail')) {
        return ok({
          'lessonId': 'l',
          'problem': {
            'studentList': [
              {
                'problemId': 'p1',
                'problem_type': 1,
                'isAnswered': true,
                'result': ['B'],
                'answer': ['A'],
              },
              {'problemId': 'p2', 'problem_type': 5, 'isAnswered': true},
              {'problemId': 'p3', 'problem_type': 1, 'isAnswered': false},
            ],
          },
        });
      }
      expect(r.queryParameters['identityId'], 'identity');
      expect(r.queryParameters['problemId'], 'p2');
      return ok({
        'content': {'problemId': 'p2', 'answer': '参考答案'},
        'problem': {
          'problemId': 'p2',
          'result': {'content': '我实际提交的内容'},
          'score': 500,
        },
      });
    });
    final result = await client(transport).ownAnswers('l', 'deck');
    expect(result['p1']!.answer, ['B']);
    expect(result['p2']!.display, '我实际提交的内容');
    expect(result['p2']!.score, 5);
    expect(result.containsKey('p3'), isFalse);
    expect(result['p1']!.source, AnswerSource.server);
    expect(
      transport.requests.every((r) => !r.headers.containsKey('Authorization')),
      isTrue,
    );
  });

  test('presentation remains viewable when answer state is unknown', () async {
    final api = client(
      FakeTransport((r) {
        if (r.uri.path.endsWith('/student/ppt')) {
          return ok({
            'presentationId': 'deck',
            'slideList': [
              {
                'id': 's',
                'index': 1,
                'cover': 'https://cdn.example/a.png',
                'visible': true,
              },
              {'id': 'hidden', 'index': 2, 'visible': false},
            ],
          });
        }
        return ok({'lessonId': 'l'});
      }),
    );
    final deck = await api.presentation('l', 'deck');
    expect(deck.slides.map((s) => s.id), ['s']);
    expect(deck.answersKnown, isFalse);
    expect(deck.answerError, contains('未知'));
  });

  test(
    'summary keeps score zero and pending score minus one as completed',
    () async {
      final api = client(
        FakeTransport(
          (r) => ok({
            'presentation': {'id': 'deck'},
            'slides': [
              {
                'problem': {'problemId': 'p0', 'problemType': 1},
                'result': {
                  'score': 0,
                  'answer': ['A'],
                },
              },
              {
                'problem': {'problemId': 'pm', 'problemType': 5},
                'result': {
                  'score': -1,
                  'answer': {'content': '待批'},
                },
              },
              {
                'problem': {'problemId': 'pn', 'problemType': 1},
                'result': {'score': null},
              },
            ],
          }),
        ),
      );
      final result = await api.ownAnswers('l', 'deck');
      expect(result['p0']!.answer, ['A']);
      expect(result['p0']!.score, 0);
      expect(result['pm']!.display, '待批');
      expect(result['pm']!.score, -1);
      expect(result.containsKey('pn'), isFalse);
    },
  );

  test(
    'ongoing personal answers use authenticated live PPT results instead of after-class summary',
    () async {
      final transport = FakeTransport((r) {
        expect(r.uri.path, '/api/v3/lesson/presentation/fetch');
        expect(r.queryParameters, {'presentation_id': 'deck'});
        expect(r.headers['Authorization'], 'Bearer http');
        return ok({
          'lessonId': 'l',
          'id': 'deck',
          'slides': [
            {
              'problem': {
                'problemId': 'choice',
                'problemType': 1,
                'answer': ['A'],
                'result': ['B'],
                'getScore': null,
              },
            },
            {
              'problem': {
                'problemId': 'subjective',
                'problemType': 5,
                'result': {'content': '另一台设备提交的答案', 'pics': []},
                'score': 1000,
              },
            },
            {
              'problem': {
                'problemId': 'unsubmitted',
                'problemType': 2,
                'result': null,
              },
            },
          ],
        });
      });
      final answers = await client(
        transport,
      ).ownAnswers('l', 'deck', session: session);
      expect(answers.keys, ['choice', 'subjective']);
      expect(answers['choice']!.answer, ['B']);
      expect(answers['choice']!.score, isNull);
      expect(answers['subjective']!.display, '另一台设备提交的答案');
      expect(answers['subjective']!.score, isNull);
      expect(
        answers.values.every((answer) => answer.source == AnswerSource.server),
        true,
      );
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'live presentation reuses embedded personal results without requesting after-class APIs',
    () async {
      final transport = FakeTransport((r) {
        expect(r.uri.path, '/api/v3/lesson/presentation/fetch');
        return ok({
          'id': 'deck',
          'slides': [
            {
              'id': 'slide',
              'index': 0,
              'problem': {
                'problemId': 'choice',
                'problemType': 1,
                'result': ['C'],
              },
            },
          ],
        });
      });
      final deck = await client(
        transport,
      ).presentation('l', 'deck', session: session);
      expect(deck.answersKnown, true);
      expect(deck.slides.single.ownAnswer!.answer, ['C']);
      expect(transport.requests, hasLength(1));
    },
  );

  for (final personal in [
    <String, dynamic>{
      'problemId': 'q',
      'problemType': 1,
      'answer': ['A'],
    },
    <String, dynamic>{'problemId': 'q', 'problemType': 1, 'result': false},
    <String, dynamic>{
      'problemId': 'q',
      'problemType': 5,
      'result': ['A'],
    },
  ]) {
    test('malformed live personal state remains unknown: $personal', () async {
      final transport = FakeTransport(
        (r) => ok({
          'id': 'deck',
          'slides': [
            {'problem': personal},
          ],
        }),
      );
      await expectLater(
        client(transport).ownAnswers('l', 'deck', session: session),
        throwsA(
          allOf(
            isA<ApiFailure>(),
            predicate((e) => e.toString().contains('未知')),
          ),
        ),
      );
      expect(transport.requests, hasLength(1));
    });
  }

  test(
    'live answer request refuses a session from another lesson before HTTP',
    () async {
      final transport = FakeTransport((r) => ok({}));
      await expectLater(
        client(transport).ownAnswers('another', 'deck', session: session),
        throwsA(isA<ApiFailure>()),
      );
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'mismatched live presentation identity cannot import another course answers',
    () async {
      final transport = FakeTransport(
        (r) => ok({'lessonId': 'other', 'id': 'deck', 'slides': []}),
      );
      await expectLater(
        client(transport).ownAnswers('l', 'deck', session: session),
        throwsA(isA<ApiFailure>()),
      );
    },
  );

  test(
    'live empty answer containers are completed while explicit null is not',
    () async {
      final api = client(
        FakeTransport(
          (r) => ok({
            'id': 'deck',
            'slides': [
              {
                'problem': {
                  'problemId': 'vote',
                  'problemType': 3,
                  'result': [],
                },
              },
              {
                'problem': {
                  'problemId': 'blank',
                  'problemType': 4,
                  'result': [],
                },
              },
              {
                'problem': {
                  'problemId': 'subjective',
                  'problemType': 5,
                  'result': {},
                },
              },
              {
                'problem': {
                  'problemId': 'unanswered',
                  'problemType': 1,
                  'result': null,
                },
              },
            ],
          }),
        ),
      );
      final answers = await api.ownAnswers('l', 'deck', session: session);
      expect(answers.keys, ['vote', 'blank', 'subjective']);
      expect(answers['vote']!.answer, isEmpty);
      expect(answers['subjective']!.answer, isEmpty);
    },
  );

  test('summary missing personal answer is unknown', () async {
    final api = client(
      FakeTransport(
        (r) => ok({
          'presentation': {'id': 'deck'},
          'slides': [
            {
              'problem': {'problemId': 'p'},
              'result': {'score': 1},
            },
          ],
        }),
      ),
    );
    await expectLater(
      api.ownAnswers('l', 'deck'),
      throwsA(
        allOf(isA<ApiFailure>(), predicate((e) => e.toString().contains('未知'))),
      ),
    );
  });

  test(
    'summary never substitutes a standard answer for a personal answer',
    () async {
      final transport = FakeTransport(
        (r) => ok({
          'presentation': {'id': 'deck'},
          'slides': [
            {
              'problem': {
                'problemId': 'p',
                'content': {
                  'answer': ['A'],
                },
              },
              'result': {'score': 0},
            },
          ],
        }),
      );
      await expectLater(
        client(transport).ownAnswers('l', 'deck'),
        throwsA(isA<ApiFailure>()),
      );
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'summary absent personal result is a known unsubmitted question',
    () async {
      final api = client(
        FakeTransport(
          (r) => ok({
            'presentation': {'id': 'deck'},
            'slides': [
              {
                'problem': {
                  'problemId': 'p',
                  'content': {
                    'answer': ['A'],
                  },
                },
              },
            ],
          }),
        ),
      );
      expect(await api.ownAnswers('l', 'deck'), isEmpty);
    },
  );

  test('checkin uses both distinct classroom tokens', () async {
    final transport = FakeTransport((r) {
      expect(r.data, {'source': 21, 'lessonId': 'l', 'joinIfNotIn': true});
      return reply(
        {
          'code': 0,
          'data': {'lessonId': 'l', 'lessonToken': 'socket-token'},
        },
        headers: {
          'set-auth': ['Bearer http-token'],
        },
      );
    });
    final result = await client(transport).checkin('l');
    expect(result.bearer, 'http-token');
    expect(result.lessonToken, 'socket-token');
  });

  test('foreign hosts are rejected before sending cookies', () async {
    final transport = FakeTransport((r) => ok({}));
    final api = client(transport);
    await expectLater(
      api.dio.get('https://example.com/'),
      throwsA(isA<DioException>()),
    );
    expect(transport.requests, isEmpty);
  });

  test('late login responses cannot restore cookies after logout', () async {
    final entered = Completer<void>(), response = Completer<ResponseBody>();
    final saved = <String>[];
    final api = client(
      FakeTransport((r) {
        entered.complete();
        return response.future;
      }),
      changed: (value) async {
        saved.add(value);
      },
    );
    final pending = api.createQr();
    final check = expectLater(pending, throwsA(isA<ApiFailure>()));
    await entered.future;
    await api.logout();
    response.complete(
      reply(
        {
          'code': 0,
          'data': {'token': 't', 'qrContent': 'q'},
        },
        headers: {
          'set-cookie': ['sessionid=late; Path=/; Secure; HttpOnly'],
        },
      ),
    );
    await check;
    expect(api.userId, isNull);
    expect(jsonDecode(await api.exportCookies()), isEmpty);
    expect(saved, ['[]']);
  });

  test(
    'position submission rechecks round and confirms server signed state',
    () async {
      var posted = false;
      final transport = FakeTransport((r) {
        expect(r.headers['Authorization'], 'Bearer http');
        if (r.uri.path.endsWith('/submit')) {
          expect(r.data, {
            'lat': 30.0,
            'lng': 120.0,
            'lessonId': 'l',
            'source': 54,
            'address': '教学楼',
          });
          posted = true;
          return reply({'code': 0});
        }
        return ok({
          'signed': posted,
          'needLocationSignIn': true,
          'session': {'id': 'round', 'centerLat': 30, 'centerLng': 120},
          'address': '教学楼',
        });
      });
      final api = client(transport);
      final confirmed = await api.locationStatus(session);
      expect(await api.locationSubmit(session, confirmed), isTrue);
      expect(
        transport.requests.where((r) => r.uri.path.endsWith('/submit')).length,
        1,
      );
    },
  );

  test('an earlier position confirmation cannot sign a new round', () async {
    final transport = FakeTransport(
      (r) => ok({
        'signed': false,
        'needLocationSignIn': true,
        'session': {'centerLat': 30, 'centerLng': 120},
      }),
    );
    final api = client(transport);
    final old = await api.locationStatus(session);
    api.locationRoundChanged('l');
    await expectLater(
      api.locationSubmit(session, old),
      throwsA(isA<ApiFailure>()),
    );
    expect(
      transport.requests.any((r) => r.uri.path.endsWith('/submit')),
      isFalse,
    );
  });

  test(
    'automatic position cancellation after the fresh query prevents POST',
    () async {
      var allowed = true;
      var queries = 0;
      final transport = FakeTransport((r) {
        expect(r.uri.path.endsWith('/submit'), false);
        queries++;
        if (queries == 2) allowed = false;
        return ok({
          'signed': false,
          'needLocationSignIn': true,
          'session': {'id': 'round', 'centerLat': 30, 'centerLng': 120},
        });
      });
      final api = client(transport);
      final target = await api.locationStatus(session);
      expect(
        await api.locationSubmit(session, target, shouldSubmit: () => allowed),
        false,
      );
      expect(queries, 2);
    },
  );

  test('a delayed location status cannot adopt a new round', () async {
    final response = Completer<ResponseBody>();
    final started = Completer<void>();
    final api = client(
      FakeTransport((r) {
        started.complete();
        return response.future;
      }),
    );
    final pending = api.locationStatus(session);
    final check = expectLater(pending, throwsA(isA<ApiFailure>()));
    await started.future;
    api.locationRoundChanged(session.lessonId);
    response.complete(ok({'signed': true, 'needLocationSignIn': false}));
    await check;
  });

  test(
    'explicit position signed evidence needs no unused target coordinates',
    () async {
      final api = client(FakeTransport((r) => ok({'signed': true})));
      final status = await api.locationStatus(session);
      expect(status.signed, true);
      expect(status.available, false);
      expect(await api.locationSubmit(session, status), true);
    },
  );

  test(
    'answer submission keeps the protocol type and millisecond time',
    () async {
      final transport = FakeTransport((r) {
        expect(r.uri.path, '/api/v3/lesson/problem/answer');
        expect(r.data['result'], ['A', 'C']);
        expect(r.data['problemType'], 2);
        expect(r.data['dt'], greaterThan(1700000000000));
        return reply({'code': 0});
      });
      await client(transport).submit(
        session,
        const Question(id: 'p', body: '多选', type: 2),
        ['A', 'C'],
      );
    },
  );
}
