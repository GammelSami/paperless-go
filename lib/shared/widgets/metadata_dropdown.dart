import 'package:flutter/material.dart';

/// Labeled dropdown for selecting an optional metadata value (correspondent,
/// document type, storage path, ...).
///
/// Generic over the item type [T]; the selection and [items] are objects (look
/// them up by id at the call site if your state stores ids). A leading "None"
/// entry represents the null selection.
///
/// Shared by the document detail, inbox quick-assign, and upload screens.
class MetadataDropdown<T> extends StatelessWidget {
  final String label;
  final T? value;
  final List<T> items;
  final String Function(T) displayName;

  /// Selection handler. When null the dropdown is disabled (e.g. mid-upload).
  final ValueChanged<T?>? onChanged;

  /// Optional decoration suffix, e.g. an "AI suggested" badge.
  final Widget? suffix;

  const MetadataDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.displayName,
    required this.onChanged,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    // Guard: if value is not in items, treat as null.
    final effectiveValue = (value != null && items.contains(value))
        ? value
        : null;
    final text = Theme.of(context).textTheme.bodyLarge;

    // Fork: a tap opens a searchable list instead of a plain dropdown menu
    // (long correspondent lists), and the value is set in regular weight.
    return InkWell(
      onTap: onChanged == null ? null : () => _pick(context, effectiveValue),
      borderRadius: BorderRadius.circular(16),
      child: InputDecorator(
        isEmpty: false,
        decoration: InputDecoration(
          labelText: label,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          isDense: true,
          enabled: onChanged != null,
          suffix: suffix,
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        child: Text(
          effectiveValue == null ? 'Keine Angabe' : displayName(effectiveValue),
          style: effectiveValue == null
              ? text?.copyWith(color: Theme.of(context).hintColor)
              : text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context, T? current) async {
    final picked = await showModalBottomSheet<_Picked<T>>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (_) => _SearchSheet<T>(
        label: label,
        items: items,
        current: current,
        displayName: displayName,
      ),
    );
    if (picked != null) onChanged?.call(picked.value);
  }
}

/// Wraps the choice so "Keine Angabe" (null) differs from "closed the sheet".
class _Picked<T> {
  const _Picked(this.value);
  final T? value;
}

class _SearchSheet<T> extends StatefulWidget {
  const _SearchSheet({
    required this.label,
    required this.items,
    required this.current,
    required this.displayName,
  });

  final String label;
  final List<T> items;
  final T? current;
  final String Function(T) displayName;

  @override
  State<_SearchSheet<T>> createState() => _SearchSheetState<T>();
}

class _SearchSheetState<T> extends State<_SearchSheet<T>> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final shown =
        [
          for (final item in widget.items)
            if (widget.displayName(item).toLowerCase().contains(q)) item,
        ]..sort(
          (a, b) => widget
              .displayName(a)
              .toLowerCase()
              .compareTo(widget.displayName(b).toLowerCase()),
        );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(
                  labelText: '${widget.label} suchen',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  if (q.isEmpty)
                    ListTile(
                      title: const Text('Keine Angabe'),
                      selected: widget.current == null,
                      onTap: () => Navigator.pop(context, _Picked<T>(null)),
                    ),
                  for (final item in shown)
                    ListTile(
                      title: Text(widget.displayName(item)),
                      selected: item == widget.current,
                      onTap: () => Navigator.pop(context, _Picked<T>(item)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
