import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_error_mapper.dart';
import '../../core/api/api_providers.dart';
import '../../core/design_tokens.dart';
import '../../core/models/custom_field.dart';
import '../../core/models/document.dart';
import '../../shared/format.dart';
import '../../shared/widgets/stamp_chip.dart';
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
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(error)));
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
                  Spacing.xl, Spacing.lg, Spacing.md, Spacing.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Inbox',
                            style: Theme.of(context).textTheme.headlineMedium),
                        Text(
                          switch (inboxState.valueOrNull?.totalCount) {
                            null => ' ',
                            0 => 'All caught up',
                            1 => '1 to sort',
                            final n => '$n to sort',
                          },
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
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
                  message:
                      friendlyApiMessage(err, fallback: 'Failed to load inbox.'),
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
          Spacing.xl, Spacing.sm, Spacing.xl, Spacing.lg),
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

  void _animateTo(Offset target, {VoidCallback? then}) {
    _animation = Tween(begin: _drag, end: target).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward(from: 0).whenComplete(() {
      _animation = null;
      then?.call();
    });
  }

  void _snapBack() => _animateTo(Offset.zero);

  Future<void> _accept(Document doc) async {
    if (_busy) return;
    setState(() => _busy = true);
    final width = MediaQuery.sizeOf(context).width;
    _animateTo(Offset(width * 1.2, 0));

    // Fork: accepting never applies Paperless' own guesses; the AI already
    // filled the fields, accept only removes the inbox tag.
    const suggestions = MetadataSuggestions();
    final notifier = ref.read(inboxNotifierProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final previous = await notifier.acceptSuggestions(doc, suggestions);
      if (!mounted) return;
      setState(() {
        _drag = Offset.zero;
        _busy = false;
      });
      if (previous != null) {
        messenger.showSnackBar(SnackBar(
          content: Text('Angenommen: "${doc.title}"'),
          // Flutter defaults an action-bearing SnackBar to persist: true
          // (snack_bar.dart: `persist = persist ?? action != null`) — without
          // this, the auto-dismiss timer fires but early-returns before
          // hiding it, and never re-arms, so it stays pinned indefinitely.
          persist: false,
          action: SnackBarAction(
            label: 'Rückgängig',
            onPressed: () => notifier.undoAccept(doc.id, previous),
          ),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _drag = Offset.zero;
        _busy = false;
      });
      messenger.showSnackBar(SnackBar(
        content: Text('Failed to file: ${friendlyApiMessage(e)}'),
      ));
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
    final api = ref.watch(paperlessApiProvider);

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.xl),
        side: BorderSide(
          color: accepting ? tokens.accentEmphasis : tokens.line,
          width: accepting ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Opacity(
          opacity: dimmed ? 0.55 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: SizedBox(
                  width: double.infinity,
                  child: ColoredBox(
                    color: tokens.paper,
                    child: CachedNetworkImage(
                      imageUrl: api.thumbnailUrl(document.id),
                      httpHeaders: {'Authorization': api.authToken},
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                      errorWidget: (_, __, ___) => Icon(
                        Icons.description_outlined,
                        size: 56,
                        color: tokens.inkSoft,
                      ),
                    ),
                  ),
                ),
              ),
              Flexible(
                flex: 3,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                      Spacing.lg, Spacing.md, Spacing.lg, Spacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        document.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: Spacing.sm),
                      if (!dimmed) _FieldSummary(document: document),
                    ],
                  ),
                ),
              ),
              if (!dimmed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      Spacing.sm, 0, Spacing.sm, Spacing.sm),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: onEdit,
                        icon: Icon(Icons.edit_outlined,
                            size: 18, color: tokens.stamp),
                        label: const Text('Bearbeiten'),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: onAccept,
                          icon: const Icon(Icons.check, size: 18),
                          label: const Text('Annehmen'),
                        ),
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

/// Fork: every field the AI filled in, plus the sentences it took deadline and
/// amount from (stored in the document note), so the card alone is enough
/// to review.
class _FieldSummary extends ConsumerWidget {
  const _FieldSummary({required this.document});

  final Document document;

  static const _quotePrefixes = ['Frist laut Text', 'Betrag laut Text'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppTokens.of(context);
    final correspondents = ref.watch(correspondentsProvider).valueOrNull ?? {};
    final docTypes = ref.watch(documentTypesProvider).valueOrNull ?? {};
    final storagePaths = ref.watch(storagePathsProvider).valueOrNull ?? {};
    final tags = ref.watch(tagsProvider).valueOrNull ?? {};
    final fieldDefs = ref.watch(customFieldsProvider).valueOrNull ?? {};
    final labelStyle = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: tokens.inkSoft);
    final valueStyle = Theme.of(context).textTheme.bodyMedium;

    final tagNames = document.tags
        .map((id) => tags[id])
        .where((t) => t != null && !t.isInboxTag)
        .map((t) => t!.name)
        .join(', ');
    final rows = <(String, String)>[
      ('Absender', correspondents[document.correspondent]?.name ?? '—'),
      ('Typ', docTypes[document.documentType]?.name ?? '—'),
      ('Kategorie', storagePaths[document.storagePath]?.name ?? '—'),
      ('Datum',
          document.created != null ? formatDate(document.created!) : '—'),
      ('Tags', tagNames.isEmpty ? '—' : tagNames),
      for (final f in document.customFields)
        if (fieldDefs[f.field] != null)
          (fieldDefs[f.field]!.name, _fieldValue(f.value, fieldDefs[f.field]!)),
    ];
    final quotes = [
      for (final n in document.notes)
        ...n.note
            .split('\n')
            .where((l) => _quotePrefixes.any((p) => l.startsWith(p))),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 84, child: Text(label, style: labelStyle)),
                Expanded(child: Text(value, style: valueStyle)),
              ],
            ),
          ),
        for (final q in quotes)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Text(q,
                style: labelStyle?.copyWith(fontStyle: FontStyle.italic)),
          ),
      ],
    );
  }

  static String _fieldValue(dynamic value, CustomField def) {
    if (value == null) return '—';
    if (def.dataType == 'boolean') return value == true ? 'Ja' : 'Nein';
    return displayCustomFieldValue(value, def.dataType,
        extraData: def.extraData);
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
          Text('Nothing to sort',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Spacing.xs),
          Text('New documents land here first.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: tokens.inkSoft)),
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
          Spacing.xl, Spacing.sm, Spacing.xl, Spacing.lg),
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
            Icon(Icons.cloud_off,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: Spacing.lg),
            Text('Failed to load inbox',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Spacing.sm),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Spacing.lg),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
