import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import '../domain/models.dart' as domain;

Rect? shareOrigin(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

AppBar fullTitleAppBar(
  BuildContext context, {
  required String title,
  bool automaticallyImplyLeading = true,
  List<Widget> actions = const [],
}) {
  return AppBar(
    automaticallyImplyLeading: automaticallyImplyLeading,
    title: Tooltip(
      message: title,
      child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    actions: actions,
  );
}

class TintedIcon extends StatelessWidget {
  final IconData icon;
  const TintedIcon(this.icon, {super.key});
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Icon(icon, size: 23, color: color),
    );
  }
}

class StatusLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  const StatusLine({
    super.key,
    required this.icon,
    required this.text,
    this.color,
  });
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        icon,
        size: 20,
        color: color ?? Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(text, style: TextStyle(color: color)),
      ),
    ],
  );
}

String formatTime(int milliseconds) {
  if (milliseconds <= 0) return '';
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
}

class ContentMessage extends StatelessWidget {
  final String text;
  final VoidCallback? retry;
  final String actionLabel;
  const ContentMessage(
    this.text, {
    this.retry,
    this.actionLabel = '重试',
    super.key,
  });
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          if (retry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: retry, child: Text(actionLabel)),
          ],
        ],
      ),
    ),
  );
}

class HtmlContent extends StatelessWidget {
  final String text;
  const HtmlContent(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Html(
    data: text,
    style: {'body': Style(margin: Margins.zero, padding: HtmlPaddings.zero)},
  );
}

class SlideImage extends StatelessWidget {
  final domain.Slide slide;
  final ImageProvider? imageProvider;
  const SlideImage(this.slide, {this.imageProvider, super.key});
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: slide.imageUrl.isEmpty && imageProvider == null
        ? const SizedBox(height: 80, child: Center(child: Text('此页没有课件图片')))
        : InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Image(
              key: ValueKey(slide.imageUrl),
              image: imageProvider ?? NetworkImage(slide.imageUrl),
              width: double.infinity,
              fit: BoxFit.fitWidth,
              // Leave the loaded image at its own aspect ratio. A fixed 4:3
              // viewport adds large bars to the usual 16:9 course slides.
              frameBuilder: (context, child, frame, synchronous) =>
                  synchronous || frame != null
                  ? child
                  : const AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Center(
                        child: SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
              errorBuilder: (context, error, stack) => const SizedBox(
                height: 80,
                child: Center(child: Text('课件图片加载失败')),
              ),
            ),
          ),
  );
}

/// A classroom uses separate scrolling panes when there is room for a viewer.
bool useWideClassroom(BoxConstraints constraints) =>
    constraints.maxWidth >= 1000 ||
    constraints.maxWidth >= 840 &&
        constraints.maxWidth > constraints.maxHeight ||
    constraints.maxWidth >= 760 && constraints.maxHeight <= 460;

/// A bounded stage keeps slides visible in full, including portrait slides.
/// The mobile feed continues to use [SlideImage] at its natural aspect ratio.
class SlideViewport extends StatelessWidget {
  final domain.Slide? slide;
  final ImageProvider? imageProvider;
  const SlideViewport(this.slide, {this.imageProvider, super.key});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: slide == null
          ? const Center(child: Text('等待教师展示课件'))
          : slide!.imageUrl.isEmpty && imageProvider == null
          ? const Center(child: Text('此页没有课件图片'))
          : LayoutBuilder(
              builder: (context, constraints) => InteractiveViewer(
                key: ValueKey(slide!.id),
                minScale: 1,
                maxScale: 5,
                child: Image(
                  image: imageProvider ?? NetworkImage(slide!.imageUrl),
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  fit: BoxFit.contain,
                  frameBuilder: (context, child, frame, synchronous) =>
                      synchronous || frame != null
                      ? child
                      : const Center(
                          child: SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                  errorBuilder: (context, error, stack) =>
                      const Center(child: Text('课件图片加载失败')),
                ),
              ),
            ),
    ),
  );
}

class SlideThumbnail extends StatelessWidget {
  final domain.Slide slide;
  final int page;
  final bool selected;

  /// Allows a classroom's separately synchronized question data to label a page.
  final String? questionLabel;
  final VoidCallback onTap;
  const SlideThumbnail({
    super.key,
    required this.slide,
    required this.page,
    required this.selected,
    this.questionLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = questionLabel?.trim().isNotEmpty == true
        ? questionLabel!.trim()
        : slide.question?.typeLabel ?? (slide.ownAnswer == null ? null : '题目');
    return Semantics(
      label: '第 $page 页${label == null ? '' : '，含题目，$label'}',
      selected: selected,
      button: true,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: slide.imageUrl.isEmpty
                    ? const Icon(Icons.slideshow_outlined)
                    : Image.network(
                        slide.imageUrl,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stack) =>
                            const Icon(Icons.slideshow_outlined),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '$page',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    if (label != null) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Tooltip(
                          message: label,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.quiz_outlined,
                                  size: 13,
                                  color: scheme.onPrimaryContainer,
                                ),
                                const SizedBox(width: 3),
                                Flexible(
                                  child: Text(
                                    label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: scheme.onPrimaryContainer,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OwnAnswer extends StatelessWidget {
  final domain.AnswerRecord record;
  const OwnAnswer(this.record, {super.key});
  @override
  Widget build(BuildContext context) {
    final pics = record.answer is Map
        ? domain.array((record.answer as Map)['pics'])
        : <dynamic>[];
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.primary.withValues(alpha: .12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.task_alt_rounded, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '我的答案 · 已提交',
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: scheme.primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(record.display.isEmpty ? '（无文字答案）' : record.display),
          for (final pic in pics)
            if (domain.firstText([
              domain.object(pic)['pic'],
              domain.object(pic)['thumb'],
            ]).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Image.network(
                  domain.firstText([
                    domain.object(pic)['pic'],
                    domain.object(pic)['thumb'],
                  ]),
                  height: 180,
                  errorBuilder: (context, error, stack) =>
                      const Text('答案图片加载失败'),
                ),
              ),
          if (record.score != null) ...[
            const SizedBox(height: 6),
            Text(record.score! < 0 ? '待批改' : '得分：${record.score}'),
          ],
        ],
      ),
    );
  }
}
