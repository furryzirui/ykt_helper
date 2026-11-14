import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/models.dart';
import 'package:ykt_helper/ui/app.dart';
import 'package:ykt_helper/ui/widgets.dart';

const _question = Question(
  id: 'q',
  body: '题目',
  type: 1,
  options: {'A': '甲', 'B': '乙', 'C': '丙'},
);
const _plain = Slide(id: 'plain', index: 0, imageUrl: '');

Future<void> _show(
  WidgetTester tester, {
  required Slide slide,
  bool selected = false,
  String? questionLabel,
  double scale = 1,
  VoidCallback? onTap,
}) => tester.pumpWidget(
  MaterialApp(
    theme: rainTheme(Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 120,
            height: 92,
            child: SlideThumbnail(
              slide: slide,
              page: 8,
              selected: selected,
              questionLabel: questionLabel,
              onTap: onTap ?? () {},
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('pure slide has only page number and no question marker', (
    tester,
  ) async {
    await _show(tester, slide: _plain);
    expect(find.text('8'), findsOneWidget);
    expect(find.byIcon(Icons.quiz_outlined), findsNothing);
    expect(find.bySemanticsLabel('第 8 页'), findsOneWidget);
  });

  for (final selected in [false, true]) {
    testWidgets(
      'question page exposes marker and semantic label selected=$selected',
      (tester) async {
        var taps = 0;
        await _show(
          tester,
          slide: const Slide(
            id: 'question',
            index: 7,
            imageUrl: '',
            question: _question,
          ),
          selected: selected,
          onTap: () => taps++,
        );
        expect(find.text(_question.typeLabel), findsOneWidget);
        expect(find.byIcon(Icons.quiz_outlined), findsOneWidget);
        expect(find.bySemanticsLabel('第 8 页，含题目，单选题'), findsOneWidget);
        await tester.tap(find.byType(SlideThumbnail));
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final type in [1, 2, 3]) {
    testWidgets('two-option protocol type $type is marked as judgment', (
      tester,
    ) async {
      await _show(
        tester,
        slide: Slide(
          id: 'judgment-$type',
          index: 7,
          imageUrl: '',
          question: Question(
            id: 'j',
            type: type,
            body: '题目',
            options: const {'A': '甲', 'B': '乙'},
          ),
        ),
      );
      expect(find.text('判断题'), findsOneWidget);
      expect(find.bySemanticsLabel('第 8 页，含题目，判断题'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('answer record alone identifies a question page', (tester) async {
    await _show(
      tester,
      slide: const Slide(
        id: 'answer-only',
        index: 7,
        imageUrl: '',
        ownAnswer: AnswerRecord(
          problemId: 'q',
          answer: 'A',
          source: AnswerSource.server,
        ),
      ),
    );
    expect(find.text('题目'), findsOneWidget);
    expect(find.byIcon(Icons.quiz_outlined), findsOneWidget);
  });

  testWidgets(
    'synchronized question label is supported without parsing the slide',
    (tester) async {
      await _show(tester, slide: _plain, questionLabel: '主观题');
      expect(find.text('主观题'), findsOneWidget);
      expect(find.bySemanticsLabel('第 8 页，含题目，主观题'), findsOneWidget);
    },
  );

  testWidgets(
    'compact large text thumbnail truncates long labels without overflow',
    (tester) async {
      const label = '单选 / 判断以及较长的题型说明';
      await _show(tester, slide: _plain, questionLabel: label, scale: 1.5);
      final text = tester.widget<Text>(find.text(label));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(find.byTooltip(label), findsOneWidget);
      expect(tester.takeException(), isNull);
      final image = tester.getRect(find.byIcon(Icons.slideshow_outlined));
      expect(image.height, greaterThan(30));
    },
  );
}
