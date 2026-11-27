import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/app/app_controller.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/ui/live_page.dart';

import 'automation_test.dart' as fixture;

void main() {
  testWidgets('题卡按固定提交时刻逐秒显示倒计时，不重新请求或推迟提交', (tester) async {
    final api = fixture.FakeRain();
    const question = Question(
      id: 'countdown-q',
      body: '倒计时选择题',
      type: 1,
      options: {'A': '甲', 'B': '乙', 'C': '丙'},
    );
    api.decks['countdown-deck'] = const Presentation(
      id: 'countdown-deck',
      title: '课件',
      slides: [
        Slide(
          id: 'countdown-slide',
          index: 0,
          imageUrl: '',
          question: question,
        ),
      ],
    );
    final controller =
        AppController(
            api: api,
            store: fixture.MemoryStore(),
            background: fixture.NoBackground(),
            autostart: const fixture.NoAutostart(),
            startTimers: false,
            connectSockets: false,
            now: tester.binding.clock.now,
          )
          ..account = const Account(id: 'u', name: '用户')
          ..settings = AppSettings(
            autoAnswer: true,
            autoSubmit: true,
            autoSubmitDelaySeconds: 30,
          );
    final live = await controller.enter(
      const Lesson(
        id: 'countdown-lesson',
        courseId: 'course',
        classroomId: 'room',
        title: '课堂',
        live: true,
      ),
    );
    await controller.processEvent(live, {
      'op': 'hello',
      'presentation': 'countdown-deck',
      'slideindex': 1,
      'timeline': [],
    });
    await controller.syncAnswers(live);
    await controller.processEvent(live, {
      'op': 'unlockproblem',
      'problem': {
        'prob': question.id,
        'pres': 'countdown-deck',
        'dt': tester.binding.clock.now().millisecondsSinceEpoch,
        'limit': 120,
      },
    });
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: QuestionCard(
              controller: controller,
              classroom: live,
              question: live.questions[question.id]!,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final deadline = controller.automaticSubmissionDeadline(live, question);
    final reads = api.answerReads, presentations = api.presentationReads.length;
    expect(deadline, isNotNull);
    expect(find.text('答案已填充，30 秒后自动提交'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('答案已填充，29 秒后自动提交'), findsOneWidget);
    expect(find.text('答案已填充，30 秒后自动提交'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('答案已填充，28 秒后自动提交'), findsOneWidget);
    expect(controller.automaticSubmissionDeadline(live, question), deadline);
    expect(api.answerReads, reads);
    expect(api.presentationReads.length, presentations);
    expect(api.submissions, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
