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
import '../../shared/error_banner.dart';
import '../../shared/format.dart';
import '../../shared/widgets/stamp_chip.dart';
import '../../shared/widgets/tag_chip.dart';
import '../documents/document_detail_screen.dart' show displayCustomFieldValue;
import '../scanner/processing/metadata_matcher.dart';
import 'inbox_edit_sheet.dart';
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
                    onTap: () => context.push('/documents/${active.id}'),
                    onAccept: () => _accept(active),
                    onEdit: () => _openEditSheet(active),
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => InboxEditSheet(document: doc),
    );
  }
}

/// Fork: Sam's layout. The page fills every pixel the info block doesn't need;
/// the info block is as tall as its content (title and correspondent wrap,
/// chips flow onto more lines) and only scrolls past 60 % of the card.
class _InboxCard extends ConsumerWidget {
  const _InboxCard({
    required this.document,
    this.onTap,
    this.onAccept,
    this.onEdit,
    this.dimmed = false,
    this.accepting = false,
  });

  final Document document;
  final VoidCallback? onTap;
  final VoidCallback? onAccept;
  final VoidCallback? onEdit;
  final bool dimmed;
  final bool accepting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTokens.of(context);

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
                ),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: box.maxHeight * 0.6),
                child: InkWell(
                  onTap: onTap,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                      Spacing.lg,
                      Spacing.md,
                      Spacing.lg,
                      Spacing.xs,
                    ),
                    child: _CardInfo(document: document),
                  ),
                ),
              ),
              if (!dimmed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.lg,
                    0,
                    Spacing.lg,
                    Spacing.md,
                  ),
                  child: Row(
                    children: [
                      IconButton.outlined(
                        onPressed: onEdit,
                        tooltip: 'Bearbeiten',
                        iconSize: 28,
                        padding: const EdgeInsets.all(Spacing.md),
                        icon: Icon(Icons.edit_outlined, color: tokens.stamp),
                      ),
                      const Spacer(),
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

/// Title, "Kategorie / Absender" + date, then document type, tags and custom
/// fields as one flowing line of chips. Inbox tags are left out (redundant here).
class _CardInfo extends ConsumerWidget {
  const _CardInfo({required this.document});

  final Document document;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTokens.of(context);
    final text = Theme.of(context).textTheme;
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
        if (fieldDefs[f.field] case final def? when f.value != null)
          _fieldLabel(f.value, def),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(document.title, style: text.titleMedium),
        const SizedBox(height: Spacing.xs),
        // Path / correspondent is never wrapped by the date: the date sits at
        // the right end when both fit on one line, otherwise it moves up onto
        // its own line above (right-aligned), and the path gets the full width.
        _OriginDateRow(
          origin: origin.isEmpty ? 'Kein Absender' : origin,
          originStyle: text.bodyMedium?.copyWith(
            color: origin.isEmpty ? tokens.inkSoft : null,
          ),
          date: document.created != null ? formatDate(document.created!) : null,
          dateStyle: text.bodyMedium?.copyWith(color: tokens.inkSoft),
        ),
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (docType != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.description_outlined,
                    size: 16,
                    color: tokens.inkSoft,
                  ),
                  const SizedBox(width: 2),
                  Text(docType, style: text.bodyMedium),
                ],
              ),
            for (final t in visibleTags) TagChip(tag: t),
            for (final label in fields) _FieldChip(label: label),
          ],
        ),
      ],
    );
  }

  static String _fieldLabel(dynamic value, CustomField def) {
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

class _OriginDateRow extends StatelessWidget {
  const _OriginDateRow({
    required this.origin,
    required this.originStyle,
    required this.date,
    required this.dateStyle,
  });

  final String origin;
  final TextStyle? originStyle;
  final String? date;
  final TextStyle? dateStyle;

  @override
  Widget build(BuildContext context) {
    final originText = Text(origin, style: originStyle);
    final date = this.date;
    if (date == null) return originText;
    final dateText = Text(date, style: dateStyle);
    return LayoutBuilder(
      builder: (context, box) {
        double widthOf(String s, TextStyle? style) => (TextPainter(
          text: TextSpan(text: s, style: style),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
        )..layout()).width;
        final fits =
            widthOf(origin, originStyle) +
                Spacing.md +
                widthOf(date, dateStyle) <=
            box.maxWidth;
        if (fits) {
          return Row(
            children: [
              Expanded(child: originText),
              dateText,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(alignment: Alignment.centerRight, child: dateText),
            originText,
          ],
        );
      },
    );
  }
}

class _FieldChip extends StatelessWidget {
  const _FieldChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(label, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

/// Page preview with Tinder-style paging: tap the right half for the next
/// page, the left half for the previous one. Shows the thumbnail until the
/// PDF is downloaded; non-PDF originals stay on the thumbnail.
class _PagedPreview extends ConsumerStatefulWidget {
  const _PagedPreview({
    super.key,
    required this.document,
    required this.interactive,
  });

  final Document document;
  final bool interactive;

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
