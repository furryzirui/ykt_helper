import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/data/secure_store.dart';
import 'package:ykt_helper/domain/models.dart';

import 'rain_api_test.dart' as fixture;

class _Store implements KeyValueStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const lesson = Lesson(
    id: 'lesson',
    courseId: 'course',
    classroomId: 'classroom',
    title: '课程标题',
  );
  const course = Course(
    courseId: 'course',
    classroomId: 'classroom',
    name: '课程',
  );

  for (final report in ['lesson-info', 'detail', 'review']) {
    test(
      'an explicit lesson_on in $report routes the same lesson to live',
      () async {
        final transport = fixture.FakeTransport((request) {
          final name = request.uri.path.split('/').last;
          if (name == report) {
            return fixture.reply({'code': 409, 'msg': 'lesson_on'});
          }
          if (name == 'lesson-info') {
            return fixture.ok({
              'lessonId': lesson.id,
              'courseId': lesson.courseId,
              'classroomId': lesson.classroomId,
              'lessonName': '当前课堂',
            });
          }
          return fixture.ok({'lessonId': lesson.id, 'timelineList': []});
        });
        final result = await fixture.client(transport).detail(lesson);
        expect(result.lesson.live, isTrue);
        expect(result.lesson.id, lesson.id);
        expect(result.lesson.courseId, lesson.courseId);
        expect(result.lesson.classroomId, lesson.classroomId);
        expect(
          result.lesson.title,
          report == 'lesson-info' ? lesson.title : '当前课堂',
        );
        expect(result.warnings, isEmpty);
        expect(
          transport.requests.every((request) => request.method == 'GET'),
          isTrue,
        );
      },
    );
  }

  test(
    'other report failures remain failures rather than guessing live state',
    () async {
      final api = fixture.client(
        fixture.FakeTransport(
          (_) => fixture.reply({'code': 42, 'msg': '其他错误'}),
        ),
      );
      await expectLater(api.detail(lesson), throwsA(isA<ApiFailure>()));
    },
  );

  test(
    'opening course history refreshes live state and preserves class association',
    () async {
      final transport = fixture.FakeTransport((request) {
        if (request.uri.path.endsWith('/on-lesson')) {
          return fixture.ok({
            'onLessonClassrooms': [
              {
                'lessonId': 'lesson',
                'courseId': 'course',
                'classroomId': 'classroom',
                'lessonName': '刚开始的课堂',
              },
              {
                'lessonId': 'other',
                'courseId': 'course',
                'classroomId': 'other-class',
                'lessonName': '另一班',
              },
            ],
          });
        }
        return fixture.ok({
          'activities': [
            {'type': 14, 'courseware_id': 'lesson', 'title': '列表旧标题'},
            {'type': 14, 'courseware_id': 'history', 'title': '历史课堂'},
          ],
          'has_more': false,
        });
      });
      final controller = AppController(
        api: fixture.client(transport),
        store: _Store(),
        startTimers: false,
        connectSockets: false,
      )..account = const Account(id: 'u', name: '用户');
      addTearDown(controller.dispose);
      final page = await controller.loadLessons(course, 0);
      expect(page.lessons.map((item) => item.id), ['lesson', 'history']);
      expect(page.lessons.first.live, isTrue);
      expect(page.lessons.first.title, '刚开始的课堂');
      expect(page.lessons.last.live, isFalse);
      expect(
        transport.requests.where((request) => request.method == 'POST'),
        isEmpty,
      );
    },
  );

  test(
    'a failed live refresh keeps history and already known live state available',
    () async {
      final transport = fixture.FakeTransport((request) {
        if (request.uri.path.endsWith('/on-lesson')) {
          return fixture.reply({'code': 42, 'msg': '实时列表暂不可用'});
        }
        return fixture.ok({
          'activities': [
            {'type': 14, 'courseware_id': 'history', 'title': '历史课堂'},
          ],
          'has_more': false,
        });
      });
      final controller =
          AppController(
              api: fixture.client(transport),
              store: _Store(),
              startTimers: false,
              connectSockets: false,
            )
            ..account = const Account(id: 'u', name: '用户')
            ..liveLessons = [
              const Lesson(
                id: 'lesson',
                courseId: 'course',
                classroomId: 'classroom',
                title: '当前课堂',
                live: true,
              ),
            ];
      addTearDown(controller.dispose);
      final page = await controller.loadLessons(course, 0);
      expect(page.lessons.map((item) => item.id), ['lesson', 'history']);
      expect(page.lessons.first.live, isTrue);
    },
  );
}
