import 'package:flutter_test/flutter_test.dart';
import 'package:ykt_helper/domain/models.dart';

void main() {
  test('the updated slide prompt targets only the requested question', () {
    expect(defaultSlidePrompt, '可以参考课程课件进行完成，若有多道题目则仅完成我要求你回答的题目');
    expect(
      AppSettings.fromJson({'slidePrompt': '可以参考课程课件进行完成'}).slidePrompt,
      defaultSlidePrompt,
    );
    for (final prompt in ['', '使用附件定义']) {
      expect(AppSettings.fromJson({'slidePrompt': prompt}).slidePrompt, prompt);
    }
  });
  test(
    'the updated default prompt migrates without replacing custom prompts',
    () {
      expect(defaultAiPrompt, '请使用最简洁的回答完成这道题，不要使用markdown：{question}');
      expect(
        AppSettings.fromJson({
          'customPrompt': '请使用最简洁的回答完成这道题：{question}',
        }).customPrompt,
        defaultAiPrompt,
      );
      for (final prompt in ['', '只输出答案：{question}']) {
        expect(
          AppSettings.fromJson({'customPrompt': prompt}).customPrompt,
          prompt,
        );
      }
    },
  );
  test(
    'removed test mode falls back to silent audio and requires fresh consent',
    () {
      final settings = AppSettings.fromJson({
        'backgroundMode': 'continuedTask',
        'iosBackgroundConsentMode': 'continuedTask',
      });
      expect(settings.backgroundMode, BackgroundServiceMode.silentAudio);
      expect(
        settings.iosBackgroundConsentMode,
        isNot(settings.backgroundMode.name),
      );
    },
  );

  test('new answer and startup settings persist with independent defaults', () {
    final fresh = AppSettings();
    expect(fresh.fixedSingleAnswer, 'A');
    expect(fresh.fixedMultipleAnswer, 'AB');
    expect(fresh.fixedJudgmentAnswer, 'A');
    expect(fresh.fixedSubjectiveAnswer, '不会');
    expect(fresh.slidePrompt, defaultSlidePrompt);
    expect(fresh.appAutoStart, isFalse);
    final saved = AppSettings(
      fixedSingleAnswer: 'B',
      fixedMultipleAnswer: 'AC',
      fixedJudgmentAnswer: 'B',
      fixedSubjectiveAnswer: '说明',
      slidePrompt: '参考附件的定义',
      appAutoStart: true,
    );
    final restored = AppSettings.fromJson(saved.toJson());
    expect(restored.fixedSingleAnswer, 'B');
    expect(restored.fixedMultipleAnswer, 'AC');
    expect(restored.fixedJudgmentAnswer, 'B');
    expect(restored.fixedSubjectiveAnswer, '说明');
    expect(restored.slidePrompt, '参考附件的定义');
    expect(restored.appAutoStart, isTrue);
    expect(saved.toJson(), isNot(contains('fixedAnswer')));
  });

  test('missing and formerly empty shared answers use requested defaults', () {
    for (final json in <Json>[
      {},
      {'fixedAnswer': ''},
      {'fixedAnswer': '   '},
    ]) {
      final settings = AppSettings.fromJson(json);
      expect(settings.fixedSingleAnswer, 'A');
      expect(settings.fixedMultipleAnswer, 'AB');
      expect(settings.fixedJudgmentAnswer, 'A');
      expect(settings.fixedSubjectiveAnswer, '不会');
      expect(settings.hasCompleteFixedAnswers, true);
    }
  });

  test('legacy shared answer migrates without coupling the new categories', () {
    final settings = AppSettings.fromJson({'fixedAnswer': 'A'});
    expect(settings.fixedSingleAnswer, 'A');
    expect(settings.fixedMultipleAnswer, 'A');
    expect(settings.fixedSubjectiveAnswer, 'A');
    expect(settings.fixedJudgmentAnswer, 'A');
    settings.fixedMultipleAnswer = 'BC';
    settings.fixedSubjectiveAnswer = '';
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.fixedSingleAnswer, 'A');
    expect(restored.fixedMultipleAnswer, 'BC');
    expect(restored.fixedSubjectiveAnswer, isEmpty);
    expect(restored.fixedJudgmentAnswer, 'A');
    expect(restored.fixedAnswer, 'A');
  });

  test('an explicit empty category or slide prompt survives serialization', () {
    final settings = AppSettings.fromJson({
      'fixedAnswer': 'old',
      'fixedSingleAnswer': '',
      'fixedMultipleAnswer': 'AB',
      'fixedJudgmentAnswer': '',
      'fixedSubjectiveAnswer': '',
      'slidePrompt': '',
    });
    expect(settings.fixedSingleAnswer, isEmpty);
    expect(settings.fixedMultipleAnswer, 'AB');
    expect(settings.fixedJudgmentAnswer, isEmpty);
    expect(settings.fixedSubjectiveAnswer, isEmpty);
    expect(settings.slidePrompt, isEmpty);
    expect(AppSettings.fromJson(settings.toJson()).slidePrompt, isEmpty);
    expect(AppSettings.fromJson({}).slidePrompt, defaultSlidePrompt);
  });

  test('explicit blank AI configuration survives serialization', () {
    for (final prompt in ['', '  \n']) {
      final settings = AppSettings(
        answerMode: AnswerMode.ai,
        baseUrl: '',
        apiKey: '',
        model: '',
        customPrompt: prompt,
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.baseUrl, isEmpty);
      expect(restored.apiKey, isEmpty);
      expect(restored.model, isEmpty);
      expect(restored.customPrompt, prompt);
    }
    expect(AppSettings.fromJson({}).customPrompt, defaultAiPrompt);
  });

  test('explicit invalid submission delays survive serialization', () {
    for (final delay in [-1, 0, 3601]) {
      final settings = AppSettings(autoSubmitDelaySeconds: delay);
      expect(
        AppSettings.fromJson(settings.toJson()).autoSubmitDelaySeconds,
        delay,
      );
    }
    expect(AppSettings.fromJson({}).autoSubmitDelaySeconds, 30);
  });

  test('fixed answers select by protocol question category', () {
    final settings = AppSettings(
      fixedSingleAnswer: 'B',
      fixedMultipleAnswer: 'AC',
      fixedSubjectiveAnswer: '说明',
    );
    for (final type in [1]) {
      expect(
        settings.fixedAnswerFor(Question(id: 'q', body: '', type: type)),
        'B',
      );
    }
    expect(
      settings.fixedAnswerFor(const Question(id: 'q', body: '', type: 6)),
      'A',
    );
    settings.fixedJudgmentAnswer = 'B';
    settings.fixedSingleAnswer = 'D';
    expect(
      settings.fixedAnswerFor(const Question(id: 'q', body: '', type: 6)),
      'B',
    );
    for (final type in [2, 3]) {
      expect(
        settings.fixedAnswerFor(Question(id: 'q', body: '', type: type)),
        'AC',
      );
    }
    for (final type in [4, 5]) {
      expect(
        settings.fixedAnswerFor(Question(id: 'q', body: '', type: type)),
        '说明',
      );
    }
    expect(
      settings.fixedAnswerFor(const Question(id: 'q', body: '', type: 7)),
      isNull,
    );
  });

  test(
    'every two-option question uses the independent judgment preference',
    () {
      final settings = AppSettings(
        fixedSingleAnswer: 'D',
        fixedMultipleAnswer: 'AC',
        fixedJudgmentAnswer: 'B',
      );
      for (final type in [1, 2, 3, 6]) {
        final question = Question(
          id: 'q',
          body: '',
          type: type,
          options: const {'A': '甲', 'B': '乙'},
        );
        expect(question.isJudgment, true);
        expect(question.typeLabel, '判断题');
        expect(settings.fixedAnswerFor(question), 'B');
      }
      const regular = Question(
        id: 'q',
        body: '',
        type: 1,
        options: {'A': '甲', 'B': '乙', 'C': '丙'},
      );
      expect(regular.isJudgment, false);
      expect(settings.fixedAnswerFor(regular), 'D');
    },
  );

  test(
    'judgment preference follows explicit right-wrong labels even when reversed',
    () {
      final settings = AppSettings();
      const reversed = Question(
        id: 'q',
        body: '',
        type: 1,
        options: {'A': '<p>错误</p>', 'B': '<p>正确</p>'},
      );
      expect(settings.fixedAnswerFor(reversed), 'B');
      settings.fixedJudgmentAnswer = 'B';
      expect(settings.fixedAnswerFor(reversed), 'A');
    },
  );
}
