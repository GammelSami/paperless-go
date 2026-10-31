import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import '../../core/api/api_error_mapper.dart';
import '../../core/api/api_providers.dart';
import '../../core/api/download_file_type.dart';
import '../../core/design_tokens.dart';
import '../../core/models/custom_field.dart';
import '../../core/models/document.dart';
import '../../core/models/tag.dart';
import '../../shared/error_banner.dart';
import '../../shared/format.dart';
import '../../shared/widgets/stamp_chip.dart';
import '../../shared/widgets/tag_chip.dart';
import '../documents/document_detail_screen.dart' show displayCustomFieldValue;
import '../scanner/processing/metadata_matcher.dart';
import 'inbox_edit_page.dart';
import 'inbox_notifier.dart';
import '../upload_queue/queue_status_banner.dart';

/// Inbox as a swipeable card stack — the highest-frequency workflow.
///
/// Swipe right / ✓ = accept OCR-matched suggestions (also files the document
/// out of the inbox). Swipe left / ✎ = edit sheet. Tap / ○ = full detail.
/// The on-card buttons are the accessible, non-gesture path to every action.
class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inboxState = ref.watch(inboxNotifierProvider);
    final tokens = AppTokens.of(context);

    ref.listen(inboxNotifierProvider, (prev, next) {
      final error = next.valueOrNull?.loadMoreError;
      if (error != null && error != prev?.valueOrNull?.loadMoreError) {
        if (context.mounted) {
          showErrorBanner(context, error);
        }
      }
    });

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Renders nothing unless an upload has actually stopped trying.
            const QueueStatusBanner(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.xl,
                Spacing.lg,
                Spacing.md,
                Spacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Inbox',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        Text(
                          switch (inboxState.valueOrNull?.totalCount) {
                            null => ' ',
                            0 => 'All caught up',
                            1 => '1 to sort',
                            final n => '$n to sort',
                          },
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: tokens.inkSoft),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: 'Search',
                    iconSize: 26,
                    onPressed: () => context.push('/search'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: 'Settings',
                    iconSize: 26,
                    onPressed: () => context.push('/settings'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: inboxState.when(
                loading: () => const _StackSkeleton(),
                error: (err, _) => _ErrorPanel(
                  message: friendlyApiMessage(
                    err,
                    fallback: 'Failed to load inbox.',
                  ),
                  onRetry: () => ref.invalidate(inboxNotifierProvider),
                ),
                data: (inbox) => inbox.documents.isEmpty
                    ? const _EmptyInbox()
                    : _CardStack(documents: inbox.documents),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardStack extends ConsumerStatefulWidget {
  const _CardStack({required this.documents});

  final List<Document> documents;

  @override
  ConsumerState<_CardStack> createState() => _CardStackState();
}

class _CardStackState extends ConsumerState<_CardStack>
    with SingleTickerProviderStateMixin {
  static const _swipeThreshold = 110.0;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Offset>? _animation;
  Offset _drag = Offset.zero;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final a = _animation;
      if (a != null) setState(() => _drag = a.value);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final docs = widget.documents;
    final active = docs.first;

    // Keep the queue topped up while sorting.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (docs.length < 5 && mounted) {
        ref.read(inboxNotifierProvider.notifier).loadMore();
      }
    });

    final width = MediaQuery.sizeOf(context).width;
    final progress = (_drag.dx / width).clamp(-1.0, 1.0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.xl,
        Spacing.sm,
        Spacing.xl,
        Spacing.lg,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Behind-cards show queue depth: scaled down, offset upward.
          for (var i = (docs.length - 1).clamp(0, 2); i >= 1; i--)
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(0, -10.0 * i + 10.0 * progress.abs()),
                child: Transform.scale(
                  scale: 1 - 0.04 * i + 0.04 * progress.abs().clamp(0, 1 / i),
                  child: _InboxCard(document: docs[i], dimmed: true),
                ),
              ),
            ),
          Positioned.fill(
            child: GestureDetector(
              onPanUpdate: _busy
                  ? null
                  : (d) => setState(() => _drag += Offset(d.delta.dx, 0)),
              onPanEnd: _busy ? null : (_) => _onPanEnd(active),
              child: Transform.translate(
                offset: _drag,
                child: Transform.rotate(
                  angle: progress * 0.06,
                  child: _InboxCard(
                    document: active,
                    onAccept: () => _accept(active),
                    onEdit: () => _openEditSheet(active),
                    onDetails: () => context.push('/documents/${active.id}'),
                    accepting: progress > 0.15,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onPanEnd(Document active) {
    if (_drag.dx > _swipeThreshold) {
      _accept(active);
    } else if (_drag.dx < -_swipeThreshold) {
      _snapBack();
      _openEditSheet(active);
    } else {
      _snapBack();
    }
  }

  Future<void> _animateTo(Offset target) {
    _animation = Tween(
      begin: _drag,
      end: target,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    return _controller.forward(from: 0).orCancel.then((_) {
      _animation = null;
    }, onError: (_) => _animation = null);
  }

  Future<void> _snapBack() => _animateTo(Offset.zero);

  Future<void> _accept(Document doc) async {
    if (_busy) return;
    setState(() => _busy = true);
    final width = MediaQuery.sizeOf(context).width;
    // Fork: let the fly-out finish before touching the offset; resetting it
    // mid-animation left the next card stuck off-screen (and, on failure,
    // the failed card gone with no buttons).
    final flyOut = _animateTo(Offset(width * 1.2, 0));

    // Fork: accepting never applies Paperless' own guesses; the AI already
    // filled the fields, accept only removes the inbox tag.
    const suggestions = MetadataSuggestions();
    final notifier = ref.read(inboxNotifierProvider.notifier);
    // Fork: success is silent (the card flying away is feedback enough);
    // only failures get a message, at the top.
    try {
      await notifier.acceptSuggestions(doc, suggestions);
      await flyOut;
      if (!mounted) return;
      setState(() {
        _drag = Offset.zero;
        _busy = false;
      });
    } catch (e) {
      await flyOut;
      if (!mounted) return;
      await _snapBack();
      if (!mounted) return;
      setState(() => _busy = false);
      showErrorBanner(
        context,
        'Annehmen fehlgeschlagen: ${friendlyApiMessage(e)}',
      );
    }
  }

  void _openEditSheet(Document doc) {
    // Full page above the bottom navigation; predictive back animates it.
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => InboxEditPage(document: doc)),
    );
  }
}

/// Fork: one type scale and one spacing rhythm for the inbox card, so sizes
/// and gaps don't drift apart. Type steps 16 / 12 / 11 come from the classic
/// modular scale (Bringhurst, The Elements of Typographic Style); every gap
/// sits on the 4-px grid.
abstract final class _CardStyle {
  static const edge = Spacing.lg; // 16: text inset from the card edge
  static const block = Spacing.sm; // 8: between blocks (title, chips, buttons)
  static const gap = Spacing.xs; // 4: between chips and tight pairs

  static TextStyle? title(BuildContext c) => Theme.of(c).textTheme.titleMedium
      ?.copyWith(fontSize: 16, fontWeight: FontWeight.w600, height: 1.25);
  static TextStyle? meta(BuildContext c) =>
      Theme.of(c).textTheme.bodySmall?.copyWith(fontSize: 12, height: 1.35);
  static TextStyle? chip(BuildContext c) => Theme.of(c).textTheme.labelSmall
      ?.copyWith(fontSize: 11, fontWeight: FontWeight.w500, height: 1.3);

  /// Shared chip box: tags and field chips are the same height.
  static const chipBorder = 1.2;
  static const chipPadV = 1.0;
}

/// Fork: Sam's layout. Everything above the button row is one big tap area
/// for paging (right half = next page, left half = previous), so the thumb
/// never has to reach the top. The info block is as tall as its content and
/// only scrolls past 60 % of the card; the page gets everything else.
/// Only the bottom row acts: pencil = quick edit, dates = full detail view,
/// ✓ accepts.
class _InboxCard extends ConsumerWidget {
  const _InboxCard({
    required this.document,
    this.onAccept,
    this.onEdit,
    this.onDetails,
    this.dimmed = false,
    this.accepting = false,
  });

  final Document document;
  final VoidCallback? onAccept;
  final VoidCallback? onEdit;

  /// Dates in the button row open the full detail view (all settings).
  final VoidCallback? onDetails;
  final bool dimmed;
  final bool accepting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTokens.of(context);
    final fieldDefs = ref.watch(customFieldsProvider).valueOrNull ?? {};
    final dateFields = [
      for (final f in document.customFields)
        if (fieldDefs[f.field] case final def?
            when def.dataType == 'date' && f.value != null)
          (def.name, DateTime.tryParse(f.value.toString())),
    ];

    Widget dateLine(IconData icon, String tooltip, DateTime? d) => Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: tokens.inkSoft),
          const SizedBox(width: _CardStyle.gap),
          Text(
            d != null ? formatDate(d) : '—',
            // Tabular digits: every number is equally wide, so stacked
            // dates line up exactly.
            style: _CardStyle.meta(context)?.copyWith(
              color: tokens.inkSoft,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.xl),
        side: BorderSide(
          color: accepting ? tokens.accentEmphasis : tokens.line,
          width: accepting ? 2 : 1,
        ),
      ),
      child: Opacity(
        opacity: dimmed ? 0.55 : 1,
        child: LayoutBuilder(
          builder: (context, box) => Column(
            children: [
              Expanded(
                child: _PagedPreview(
                  key: ValueKey(document.id),
                  document: document,
                  interactive: !dimmed,
                  maxInfoHeight: box.maxHeight * 0.6,
                  info: _CardInfo(document: document),
                ),
              ),
              if (!dimmed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.sm,
                    0,
                    Spacing.lg,
                    Spacing.md,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: onEdit,
                        tooltip: 'Bearbeiten',
                        iconSize: 28,
                        icon: Icon(
                          Icons.edit,
                          color: tokens.stamp.withValues(alpha: 0.85),
                        ),
                      ),
                      Expanded(
                        child: InkWell(
                          onTap: onDetails,
                          borderRadius: BorderRadius.circular(Radii.md),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: Spacing.sm,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                dateLine(
                                  Icons.description_outlined,
                                  'Dokumentdatum',
                                  document.created,
                                ),
                                for (final (name, d) in dateFields)
                                  dateLine(Icons.priority_high, name, d),
                              ],
                            ),
                          ),
                        ),
                      ),
                      IconButton.filled(
                        onPressed: onAccept,
                        tooltip: 'Annehmen',
                        iconSize: 28,
                        padding: const EdgeInsets.all(Spacing.md),
                        icon: const Icon(Icons.check),
                      ),
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

/// Document type written sideways along the left edge; next to it the title,
/// "Kategorie / Absender", then non-date custom fields and finally the tags.
/// Inbox tags are left out (redundant here); dates live in the button row.
class _CardInfo extends ConsumerWidget {
  const _CardInfo({required this.document});

  /// Same space left and right of the sideways type.
  static const _labelGap = 10.0;

  final Document document;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTokens.of(context);
    final correspondents = ref.watch(correspondentsProvider).valueOrNull ?? {};
    final docTypes = ref.watch(documentTypesProvider).valueOrNull ?? {};
    final storagePaths = ref.watch(storagePathsProvider).valueOrNull ?? {};
    final tags = ref.watch(tagsProvider).valueOrNull ?? {};
    final fieldDefs = ref.watch(customFieldsProvider).valueOrNull ?? {};

    final origin = [
      storagePaths[document.storagePath]?.name,
      correspondents[document.correspondent]?.name,
    ].whereType<String>().join(' / ');
    final docType = docTypes[document.documentType]?.name;
    final visibleTags = [
      for (final id in document.tags)
        if (tags[id] case final t? when !t.isInboxTag) t,
    ];
    final fields = [
      for (final f in document.customFields)
        if (fieldDefs[f.field] case final def?
            when f.value != null && def.dataType != 'date')
          _fieldLabel(f.value, def),
    ];

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(document.title, style: _CardStyle.title(context)),
        const SizedBox(height: _CardStyle.gap),
        Text(
          origin.isEmpty ? 'Kein Absender' : origin,
          style: _CardStyle.meta(context),
        ),
        if (fields.isNotEmpty || visibleTags.isNotEmpty) ...[
          const SizedBox(height: _CardStyle.block),
          if (fields.isNotEmpty) _PackedChips(fieldLabels: fields),
          if (fields.isNotEmpty && visibleTags.isNotEmpty)
            const SizedBox(height: _CardStyle.gap),
          if (visibleTags.isNotEmpty) _PackedChips(tags: visibleTags),
        ],
      ],
    );
    // Info inset is 10 (see _PagedPreview); without the sideways type the
    // text gets the card's normal 16.
    if (docType == null) {
      return Padding(
        padding: const EdgeInsets.only(left: _CardStyle.edge - _labelGap),
        child: details,
      );
    }

    // Sideways label in a Stack (not IntrinsicHeight, which can't measure the
    // LayoutBuilder in the tag block): it spans exactly the details' height.
    const labelWidth = 16.0;
    final rule = Container(
      height: 1.5,
      color: tokens.inkSoft.withValues(alpha: 0.45),
    );
    // The rule starts at the title's cap height and ends on the last tag's
    // edge (or the origin's baseline when there are no chips), not at the
    // line boxes, whose built-in leading would make it overshoot.
    TextPainter line(String t, TextStyle? st) => TextPainter(
      text: TextSpan(text: t, style: st),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    const interCapHeight = 0.727; // Inter: capHeight 1490 / unitsPerEm 2048
    final titleStyle = _CardStyle.title(context);
    final titleLine = line(document.title, titleStyle);
    final top =
        titleLine.computeDistanceToActualBaseline(TextBaseline.alphabetic) -
        MediaQuery.textScalerOf(context).scale(titleStyle?.fontSize ?? 16) *
            interCapHeight;
    final metaLine = line(origin, _CardStyle.meta(context));
    final bottom = fields.isNotEmpty || visibleTags.isNotEmpty
        ? 0.0
        : metaLine.height -
              metaLine.computeDistanceToActualBaseline(TextBaseline.alphabetic);

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: labelWidth + _labelGap),
          child: details,
        ),
        Positioned(
          // Measured on screen: centred between card edge and text (the
          // title's side bearing and the card border shift it by ~1.5).
          left: 1.5,
          top: top,
          bottom: bottom,
          width: labelWidth,
          // Rule – type – rule, turned upright: marks the info block from the
          // title to the last tag, with the type centred in the line.
          child: RotatedBox(
            quarterTurns: 3,
            child: Row(
              children: [
                Expanded(child: rule),
                Flexible(
                  flex: 0,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _CardStyle.gap,
                    ),
                    child: Text(
                      docType,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // height 1: the line box must fit the 16-px column,
                      // or descenders (the g in "Vertrag") get clipped.
                      style: _CardStyle.chip(
                        context,
                      )?.copyWith(color: tokens.inkSoft, height: 1),
                    ),
                  ),
                ),
                Expanded(child: rule),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _fieldLabel(dynamic value, CustomField def) {
    // The amount speaks for itself (sign and €), no "Betrag:" prefix.
    if (def.dataType == 'monetary') return formatMoney(value.toString());
    if (def.dataType == 'boolean') {
      return value == true ? '${def.name} ✓' : '${def.name} ✗';
    }
    final shown = def.dataType == 'monetary'
        ? formatMoney(value.toString())
        : displayCustomFieldValue(
            value,
            def.dataType,
            extraData: def.extraData,
          );
    return '${def.name}: $shown';
  }
}

/// Chips packed to fill the width: longest first into the first line they fit
/// (first-fit decreasing), then every chip gets the same extra padding,
/// as much as the fullest line allows (capped), to use spare width evenly.
class _PackedChips extends StatelessWidget {
  const _PackedChips({this.tags = const [], this.fieldLabels = const []});

  final List<Tag> tags;
  final List<String> fieldLabels;

  /// Inner padding (text to pill edge) and outer gap (pill to pill) are one
  /// value, so the space inside and between pills looks the same.
  static const _minSpace = 4.0;
  static const _maxSpace = 10.0;

  @override
  Widget build(BuildContext context) {
    final style = InboxTagChip.textStyle(context);
    final scaler = MediaQuery.textScalerOf(context);
    final chips = <({String label, Tag? tag})>[
      for (final label in fieldLabels) (label: label, tag: null),
      for (final tag in tags) (label: tag.name, tag: tag),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        // Width of a pill without its horizontal padding.
        double core(({String label, Tag? tag}) chip) =>
            (TextPainter(
              text: TextSpan(text: chip.label, style: style),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
              maxLines: 1,
            )..layout()).width +
            2 * InboxTagChip.borderWidth;

        // Balance instead of fill: find the fewest lines that fit, deal the
        // tags out longest-first onto the currently shortest line (so lines
        // end up about equally full), then give every pill the same spacing,
        // as much as the fullest line allows. No squeezed line above an
        // almost empty one.
        final cs = {for (final chip in chips) chip: core(chip)};
        final sorted = [...chips]..sort((a, b) => cs[b]!.compareTo(cs[a]!));
        double need(double c, int n) => c + (3 * n - 1) * _minSpace;
        var lines = <List<({String label, Tag? tag})>>[];
        var cores = <double>[];
        for (var count = 1; count <= chips.length; count++) {
          lines = [
            for (var j = 0; j < count; j++) <({String label, Tag? tag})>[],
          ];
          cores = List.filled(count, 0.0);
          for (final chip in sorted) {
            var j = 0;
            for (var k = 1; k < count; k++) {
              if (need(cores[k], lines[k].length) <
                  need(cores[j], lines[j].length)) {
                j = k;
              }
            }
            lines[j].add(chip);
            cores[j] += cs[chip]!;
          }
          final fitsAll = [
            for (var j = 0; j < count; j++)
              need(cores[j], lines[j].length) <= box.maxWidth,
          ].every((ok) => ok);
          if (fitsAll) break;
        }

        // A line of n pills has 2n paddings and n-1 gaps, all equal.
        final space = [
          for (var j = 0; j < lines.length; j++)
            if (lines[j].isNotEmpty)
              (box.maxWidth - cores[j]) / (3 * lines[j].length - 1),
        ].reduce((a, b) => a < b ? a : b).clamp(_minSpace, _maxSpace);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var j = 0; j < lines.length; j++)
              Padding(
                padding: EdgeInsets.only(top: j == 0 ? 0 : _CardStyle.gap),
                child: Row(
                  children: [
                    // Every second line runs short-to-long, so the long
                    // pills don't all pile up on the left.
                    for (final (i, chip)
                        in (j.isOdd ? lines[j].reversed : lines[j])
                            .indexed) ...[
                      if (i > 0) SizedBox(width: space),
                      if (chip.tag case final tag?)
                        InboxTagChip(tag: tag, hPad: space)
                      else
                        _FieldChip(label: chip.label, hPad: space),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Fork: inbox tag look — outline in a softened tag colour, a faint tint
/// inside, and text that is mostly ink with a touch of the tag colour.
class InboxTagChip extends StatelessWidget {
  const InboxTagChip({super.key, required this.tag, required this.hPad});

  final Tag tag;
  final double hPad;

  static const borderWidth = _CardStyle.chipBorder;

  static TextStyle? textStyle(BuildContext context) => _CardStyle.chip(context);

  @override
  Widget build(BuildContext context) {
    final c = TagChip.colorOf(context, tag);
    return Semantics(
      label: '${tag.name} tag',
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: hPad,
          vertical: _CardStyle.chipPadV,
        ),
        decoration: BoxDecoration(
          color: TagChip.fill(c),
          border: Border.all(color: TagChip.outline(c), width: borderWidth),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(
          tag.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: textStyle(
            context,
          )?.copyWith(color: TagChip.textColor(context, c)),
        ),
      ),
    );
  }
}

class _FieldChip extends StatelessWidget {
  const _FieldChip({required this.label, required this.hPad});

  final String label;
  final double hPad;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: hPad,
        vertical: _CardStyle.chipPadV,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.line, width: _CardStyle.chipBorder),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(label, style: _CardStyle.chip(context)),
    );
  }
}

/// Page preview plus [info] below it, as one tap area: tap the right half for
/// the next page, the left half for the previous one (Tinder-style). Shows the
/// thumbnail until the PDF is downloaded; non-PDF originals stay on it.
class _PagedPreview extends ConsumerStatefulWidget {
  const _PagedPreview({
    super.key,
    required this.document,
    required this.interactive,
    required this.info,
    required this.maxInfoHeight,
  });

  final Document document;
  final bool interactive;
  final Widget info;
  final double maxInfoHeight;

  @override
  ConsumerState<_PagedPreview> createState() => _PagedPreviewState();
}

class _PagedPreviewState extends ConsumerState<_PagedPreview> {
  PdfDocument? _pdf;
  final _pages = <int, Uint8List>{};
  int _page = 1;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    if (widget.interactive) _open();
  }

  @override
  void didUpdateWidget(_PagedPreview old) {
    super.didUpdateWidget(old);
    if (widget.interactive && !old.interactive && _pdf == null) _open();
  }

  Future<void> _open() async {
    try {
      final api = ref.read(paperlessApiProvider);
      final dir = await getTemporaryDirectory();
      final id = widget.document.id;
      final file = await api.downloadDocumentTyped(
        id,
        (ext) => '${dir.path}/inbox_$id.$ext',
      );
      if (_disposed || !isPdfFile(file.path)) return;
      final pdf = await PdfDocument.openFile(file.path);
      if (_disposed) return pdf.close();
      setState(() => _pdf = pdf);
    } on Exception {
      // Thumbnail stays; paging just isn't available for this document.
    }
  }

  Future<void> _show(int page) async {
    final pdf = _pdf;
    if (pdf == null || page < 1 || page > pdf.pagesCount) return;
    setState(() => _page = page);
    if (_pages.containsKey(page)) return;
    final p = await pdf.getPage(page);
    final img = await p.render(
      width: p.width * 2,
      height: p.height * 2,
      format: PdfPageImageFormat.png,
    );
    await p.close();
    if (!_disposed && img != null) setState(() => _pages[page] = img.bytes);
  }

  @override
  void dispose() {
    _disposed = true;
    _pdf?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    final api = ref.watch(paperlessApiProvider);
    final count = _pdf?.pagesCount ?? 1;
    final bytes = _pages[_page];

    final image = bytes != null
        ? Image.memory(
            bytes,
            fit: BoxFit.fitWidth,
            alignment: Alignment.topCenter,
            gaplessPlayback: true,
          )
        : CachedNetworkImage(
            imageUrl: api.thumbnailUrl(widget.document.id),
            httpHeaders: {'Authorization': api.authToken},
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            errorWidget: (_, __, ___) => Icon(
              Icons.description_outlined,
              size: 56,
              color: tokens.inkSoft,
            ),
          );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: widget.interactive && count > 1
          ? (d) => _show(
              d.localPosition.dx > context.size!.width / 2
                  ? _page + 1
                  : _page - 1,
            )
          : null,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: tokens.paper, child: image),
                if (count > 1)
                  Positioned(
                    top: Spacing.sm,
                    left: Spacing.sm,
                    right: Spacing.sm,
                    child: Row(
                      children: [
                        for (var i = 1; i <= count; i++)
                          Expanded(
                            child: Container(
                              height: 4,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              decoration: BoxDecoration(
                                color: i == _page
                                    ? Colors.black54
                                    : Colors.black.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.maxInfoHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                _CardInfo._labelGap,
                _CardStyle.block,
                _CardStyle.edge,
                _CardStyle.block,
              ),
              child: widget.info,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyInbox extends StatelessWidget {
  const _EmptyInbox();

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const StampChip(label: 'ALL CAUGHT UP', rotated: true),
          const SizedBox(height: Spacing.lg),
          Text(
            'Nothing to sort',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            'New documents land here first.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: tokens.inkSoft),
          ),
          const SizedBox(height: Spacing.lg),
          TextButton.icon(
            onPressed: () => GoRouter.of(context).go('/scan'),
            icon: const Icon(Icons.document_scanner_outlined, size: 18),
            label: const Text('Scan something'),
          ),
        ],
      ),
    );
  }
}

class _StackSkeleton extends StatelessWidget {
  const _StackSkeleton();

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    Widget bar(double w) => Container(
      height: 14,
      width: w,
      decoration: BoxDecoration(
        color: tokens.line,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.xl,
        Spacing.sm,
        Spacing.xl,
        Spacing.lg,
      ),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SizedBox(
                  width: double.infinity,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tokens.paper,
                      borderRadius: BorderRadius.circular(Radii.md),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Spacing.lg),
              bar(220),
              const SizedBox(height: Spacing.sm),
              bar(140),
              const SizedBox(height: Spacing.lg),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: Spacing.lg),
            Text(
              'Failed to load inbox',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Spacing.lg),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
