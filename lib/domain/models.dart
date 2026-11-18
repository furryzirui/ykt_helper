typedef Json = Map<String, dynamic>;

Json object(dynamic value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : <String, dynamic>{};
List<dynamic> array(dynamic value) => value is List ? value : <dynamic>[];
String str(dynamic value) => value?.toString() ?? '';
int integer(dynamic value, [int fallback = 0]) =>
    value is num ? value.toInt() : int.tryParse(str(value)) ?? fallback;
bool truth(dynamic value) => value == true || value == 1 || value == '1';
String firstText(Iterable<dynamic> values) =>
    values.map(str).firstWhere((value) => value.isNotEmpty, orElse: () => '');

class Account {
  final String id, name, school;
  const Account({required this.id, required this.name, this.school = ''});
  factory Account.fromJson(Json json) => Account(
    id: str(json['user_id'] ?? json['id']),
    name: str(json['name']),
    school: str(json['school']),
  );
  Json toJson() => {'id': id, 'name': name, 'school': school};
}

class Course {
  final String courseId, classroomId, name, classroomName, teacher;
  final bool archived;
  final List<String> liveLessonIds;
  const Course({
    required this.courseId,
    required this.classroomId,
    required this.name,
    this.classroomName = '',
    this.teacher = '',
    this.archived = false,
    this.liveLessonIds = const [],
  });
  String get key => '$courseId:$classroomId';
  Course withLive(List<String> ids) => Course(
    courseId: courseId,
    classroomId: classroomId,
    name: name,
    classroomName: classroomName,
    teacher: teacher,
    archived: archived,
    liveLessonIds: ids,
  );
}

class Lesson {
  final String id, courseId, classroomId, title;
  final int startedAt, endedAt;
  final bool live, oldVersion;
  const Lesson({
    required this.id,
    required this.courseId,
    required this.classroomId,
    required this.title,
    this.startedAt = 0,
    this.endedAt = 0,
    this.live = false,
    this.oldVersion = false,
  });
}

class LessonPage {
  final List<Lesson> lessons;
  final bool hasMore;
  const LessonPage(this.lessons, this.hasMore);
}

class ClassroomSession {
  final String userId, lessonId, bearer, lessonToken;
  const ClassroomSession({
    required this.userId,
    required this.lessonId,
    required this.bearer,
    required this.lessonToken,
  });
  String get key => '$userId:$lessonId';
}

class Question {
  final String id, body;
  final int type;
  final Map<String, String> options;
  final int blankCount, selectionLimit;
  final int dt, limit, serverOffsetMillis;
  const Question({
    required this.id,
    required this.body,
    required this.type,
    this.options = const {},
    this.blankCount = 1,
    this.selectionLimit = 1,
    this.dt = 0,
    this.limit = 0,
    this.serverOffsetMillis = 0,
  });
  factory Question.fromJson(Json json) {
    final content = object(json['content']);
    final options = <String, String>{};
    final rawOptions = json['options'] ?? content['options'];
    if (rawOptions is Map) {
      rawOptions.forEach((key, value) {
        options[str(key)] = str(value);
      });
    } else {
      for (final item in array(rawOptions)) {
        final option = object(item);
        final key = str(option['key']);
        if (key.isNotEmpty) options[key] = str(option['value']);
      }
    }
    return Question(
      id: str(json['problemId'] ?? json['id']),
      body: firstText([json['body'], content['body'], content['title']]),
      type: integer(json['problemType'] ?? json['type']),
      options: options,
      selectionLimit: integer(
        json['pollingCount'] ?? content['pollingCount'],
        1,
      ).clamp(1, 100),
      blankCount: array(
        json['blanks'] ?? content['blanks'],
      ).length.clamp(1, 100),
      dt: integer(json['dt']),
      limit: integer(json['limit']),
    );
  }
  Question launched(int timestamp, int seconds, {int? serverOffsetMillis}) =>
      Question(
        id: id,
        body: body,
        type: type,
        options: options,
        blankCount: blankCount,
        selectionLimit: selectionLimit,
        dt: timestamp,
        limit: seconds,
        serverOffsetMillis: serverOffsetMillis ?? this.serverOffsetMillis,
      );
  bool get isJudgment => type == 6 || options.length == 2;

  String get typeLabel => isJudgment
      ? '判断题'
      : switch (type) {
          1 => '单选题',
          2 => '多选',
          3 => '投票',
          4 => '填空',
          5 => '主观题',
          6 => '判断题',
          _ => '题目',
        };
  String get promptText =>
      [body, ...options.entries.map((e) => '${e.key}. ${e.value}')].join('\n');
}

enum AnswerSource { local, server }

class AnswerRecord {
  final String problemId;
  final dynamic answer;
  final AnswerSource source;
  final num? score;
  final int submittedAt;
  const AnswerRecord({
    required this.problemId,
    required this.answer,
    required this.source,
    this.score,
    this.submittedAt = 0,
  });
  String get display {
    if (answer is List) return (answer as List).map(str).join('、');
    if (answer is Map) return str((answer as Map)['content']);
    return str(answer);
  }

  Json toJson() => {
    'problemId': problemId,
    'answer': answer,
    'score': score,
    'submittedAt': submittedAt,
  };
  factory AnswerRecord.fromJson(Json json) => AnswerRecord(
    problemId: str(json['problemId']),
    answer: json['answer'],
    score: json['score'] is num ? json['score'] as num : null,
    submittedAt: integer(json['submittedAt']),
    source: AnswerSource.local,
  );
}

class Slide {
  final String id, imageUrl, text;
  final int index;
  final Question? question;
  final AnswerRecord? ownAnswer;
  const Slide({
    required this.id,
    required this.index,
    required this.imageUrl,
    this.text = '',
    this.question,
    this.ownAnswer,
  });
}

class Presentation {
  final String id, title;
  final List<Slide> slides;
  final bool answersKnown;
  final String? answerError;
  const Presentation({
    required this.id,
    required this.title,
    required this.slides,
    this.answersKnown = false,
    this.answerError,
  });
}

class PresentationRef {
  final String id, title;
  const PresentationRef(this.id, this.title);
}

enum AttendanceStatus { unknown, signed, unsigned }

extension AttendanceLabel on AttendanceStatus {
  String get label => switch (this) {
    AttendanceStatus.unknown => '签到状态未同步',
    AttendanceStatus.signed => '已签到',
    AttendanceStatus.unsigned => '未签到',
  };
}

class LessonDetail {
  final Lesson lesson;
  final String teacher, checkinText;
  final List<PresentationRef> presentations;
  final Map<String, AnswerRecord> answers;
  final List<Slide> reviewSlides;
  final bool answersKnown;
  final String? answerError;
  final List<String> warnings;
  const LessonDetail({
    required this.lesson,
    this.teacher = '',
    this.checkinText = '签到状态待确认',
    this.presentations = const [],
    this.answers = const {},
    this.reviewSlides = const [],
    this.answersKnown = false,
    this.answerError,
    this.warnings = const [],
  });
}

class LocationCheckin {
  final bool signed, available;
  final double? latitude, longitude;
  final String address, roundId;
  const LocationCheckin({
    required this.signed,
    required this.available,
    this.latitude,
    this.longitude,
    this.address = '',
    this.roundId = '',
  });
  String get fingerprint => '$roundId:$latitude:$longitude';
}

enum AnswerMode { fixed, ai }

enum SlideScope { none, current, currentAndNext, all }

enum BackgroundServiceMode { native, silentAudio, pictureInPicture, location }

const serviceTimeoutOptions = [0, 10, 120, 1440];

const defaultAiPrompt = '请使用最简洁的回答完成这道题：{question}';
const defaultSlidePrompt = '可以参考课程课件进行完成';
const defaultFixedSingleAnswer = 'A';
const defaultFixedMultipleAnswer = 'AB';
const defaultFixedJudgmentAnswer = 'A';
const defaultFixedSubjectiveAnswer = '不会';

class AppSettings {
  /// Lets an enabled automation start the service when needed. The direct
  /// system-service switch is a process-local control in AppController and is
  /// deliberately not persisted.
  bool autoStartService, appAutoStart, autoEnter, autoAnswer, autoSubmit;
  int autoSubmitDelaySeconds;
  int serviceTimeoutMinutes;
  BackgroundServiceMode backgroundMode;
  String? iosBackgroundConsentMode;
  AnswerMode answerMode;
  String fixedSingleAnswer,
      fixedMultipleAnswer,
      fixedJudgmentAnswer,
      fixedSubjectiveAnswer;
  String baseUrl, apiKey, model, customPrompt, slidePrompt;
  SlideScope slideScope;
  AppSettings({
    this.autoStartService = false,
    this.appAutoStart = false,
    this.autoEnter = false,
    this.autoAnswer = false,
    this.autoSubmit = false,
    this.autoSubmitDelaySeconds = 30,
    this.serviceTimeoutMinutes = 0,
    this.backgroundMode = BackgroundServiceMode.silentAudio,
    this.iosBackgroundConsentMode,
    this.answerMode = AnswerMode.fixed,
    String fixedAnswer = '',
    String? fixedSingleAnswer,
    String? fixedMultipleAnswer,
    this.fixedJudgmentAnswer = defaultFixedJudgmentAnswer,
    String? fixedSubjectiveAnswer,
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.customPrompt = defaultAiPrompt,
    this.slidePrompt = defaultSlidePrompt,
    this.slideScope = SlideScope.none,
  }) : fixedSingleAnswer =
           fixedSingleAnswer ??
           (fixedAnswer.trim().isEmpty
               ? defaultFixedSingleAnswer
               : fixedAnswer),
       fixedMultipleAnswer =
           fixedMultipleAnswer ??
           (fixedAnswer.trim().isEmpty
               ? defaultFixedMultipleAnswer
               : fixedAnswer),
       fixedSubjectiveAnswer =
           fixedSubjectiveAnswer ??
           (fixedAnswer.trim().isEmpty
               ? defaultFixedSubjectiveAnswer
               : fixedAnswer);

  // Legacy source callers can still construct the former shared answer; new
  // settings are persisted separately and never fall back between categories.
  String get fixedAnswer => fixedSingleAnswer;
  set fixedAnswer(String value) {
    fixedSingleAnswer = fixedMultipleAnswer = fixedJudgmentAnswer =
        fixedSubjectiveAnswer = value;
  }

  String? fixedAnswerFor(Question question) {
    if (question.isJudgment) {
      if (!const ['A', 'B'].contains(fixedJudgmentAnswer)) {
        return fixedJudgmentAnswer;
      }
      if (question.options.length == 2) {
        final labels = question.options.map(
          (key, value) => MapEntry(
            key,
            value
                .replaceAll(RegExp(r'<[^>]*>'), '')
                .replaceAll('&nbsp;', ' ')
                .trim(),
          ),
        );
        for (final pair in const [
          ['正确', '错误'],
          ['对', '错'],
        ]) {
          if (labels.values.contains(pair[0]) &&
              labels.values.contains(pair[1])) {
            final label = fixedJudgmentAnswer == 'A' ? pair[0] : pair[1];
            return labels.entries
                .singleWhere((entry) => entry.value == label)
                .key;
          }
        }
      }
      return fixedJudgmentAnswer;
    }
    return switch (question.type) {
      1 => fixedSingleAnswer,
      2 || 3 => fixedMultipleAnswer,
      6 => fixedJudgmentAnswer,
      4 || 5 => fixedSubjectiveAnswer,
      _ => null,
    };
  }

  bool get hasCompleteFixedAnswers => [
    fixedSingleAnswer,
    fixedMultipleAnswer,
    fixedJudgmentAnswer,
    fixedSubjectiveAnswer,
  ].every((answer) => answer.trim().isNotEmpty);

  factory AppSettings.fromJson(Json json) => AppSettings(
    autoStartService: truth(json['autoStartService']),
    appAutoStart: truth(json['appAutoStart']),
    autoEnter: truth(json['autoEnter']),
    autoAnswer: truth(json['autoAnswer']),
    autoSubmit: truth(json['autoSubmit']),
    autoSubmitDelaySeconds: integer(json['autoSubmitDelaySeconds'], 30),
    serviceTimeoutMinutes:
        serviceTimeoutOptions.contains(json['serviceTimeoutMinutes'])
        ? integer(json['serviceTimeoutMinutes'])
        : 0,
    backgroundMode: BackgroundServiceMode.values.firstWhere(
      (mode) => mode.name == json['backgroundMode'],
      orElse: () => BackgroundServiceMode.silentAudio,
    ),
    iosBackgroundConsentMode: json['iosBackgroundConsentMode'] is String
        ? json['iosBackgroundConsentMode'] as String
        : null,
    answerMode: json['answerMode'] == 'ai' ? AnswerMode.ai : AnswerMode.fixed,
    fixedAnswer: str(json['fixedAnswer']),
    fixedSingleAnswer: json.containsKey('fixedSingleAnswer')
        ? str(json['fixedSingleAnswer'])
        : null,
    fixedMultipleAnswer: json.containsKey('fixedMultipleAnswer')
        ? str(json['fixedMultipleAnswer'])
        : null,
    fixedJudgmentAnswer: json.containsKey('fixedJudgmentAnswer')
        ? str(json['fixedJudgmentAnswer'])
        : defaultFixedJudgmentAnswer,
    fixedSubjectiveAnswer: json.containsKey('fixedSubjectiveAnswer')
        ? str(json['fixedSubjectiveAnswer'])
        : null,
    baseUrl: str(json['baseUrl']),
    apiKey: str(json['apiKey']),
    model: str(json['model']),
    customPrompt: json.containsKey('customPrompt')
        ? str(json['customPrompt'])
        : defaultAiPrompt,
    slidePrompt: json.containsKey('slidePrompt')
        ? str(json['slidePrompt'])
        : defaultSlidePrompt,
    slideScope: SlideScope.values.firstWhere(
      (e) => e.name == json['slideScope'],
      orElse: () => SlideScope.none,
    ),
  );
  Json toJson() => {
    'autoStartService': autoStartService,
    'appAutoStart': appAutoStart,
    'autoEnter': autoEnter,
    'autoAnswer': autoAnswer,
    'autoSubmit': autoSubmit,
    'autoSubmitDelaySeconds': autoSubmitDelaySeconds,
    'serviceTimeoutMinutes': serviceTimeoutMinutes,
    'backgroundMode': backgroundMode.name,
    'iosBackgroundConsentMode': iosBackgroundConsentMode,
    'answerMode': answerMode.name,
    'fixedSingleAnswer': fixedSingleAnswer,
    'fixedMultipleAnswer': fixedMultipleAnswer,
    'fixedJudgmentAnswer': fixedJudgmentAnswer,
    'fixedSubjectiveAnswer': fixedSubjectiveAnswer,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'model': model,
    'customPrompt': customPrompt,
    'slidePrompt': slidePrompt,
    'slideScope': slideScope.name,
  };
}

class ApiFailure implements Exception {
  final String message;
  final int? code;
  const ApiFailure(this.message, [this.code]);
  @override
  String toString() => message;
}
