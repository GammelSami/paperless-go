import 'package:flutter/material.dart';

/// Labeled dropdown for selecting an optional metadata value (correspondent,
/// document type, storage path, ...).
///
/// Generic over the item type [T]; the selection and [items] are objects (look
/// them up by id at the call site if your state stores ids). A leading "None"
/// entry represents the null selection.
///
/// Shared by the document detail, inbox quick-assign, and upload screens.
class MetadataDropdown<T> extends StatefulWidget {
  final String label;
  final T? value;
  final List<T> items;
  final String Function(T) displayName;
  final Widget Function(T)? leadingIcon;

  /// Selection handler. When null the dropdown is disabled (e.g. mid-upload).
  final ValueChanged<T?>? onChanged;

  /// Optional decoration suffix, e.g. an "AI suggested" badge.
  final Widget? suffix;

  /// Text of the "nothing selected" entry. Empty = no such entry (e.g. an
  /// "add tag" field that resets after every pick).
  final String emptyLabel;

  /// When set, typing a name that matches no item offers "Neu anlegen" and
  /// hands the typed name here. Needs an empty [emptyLabel] (it reuses the
  /// null entry).
  final ValueChanged<String>? onCreate;
  final MenuController? menuController;

  const MetadataDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.displayName,
    this.leadingIcon,
    required this.onChanged,
    this.suffix,
    this.emptyLabel = 'Keine Angabe',
    this.onCreate,
    this.menuController,
  }) : assert(onCreate == null || emptyLabel == '');

  @override
  State<MetadataDropdown<T>> createState() => _MetadataDropdownState<T>();
}

class _MetadataDropdownState<T> extends State<MetadataDropdown<T>> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The "create" entry depends on the typed text.
    _controller.addListener(() {
      if (widget.onCreate != null && mounted) setState(() {});
    });
    // Select the current text on focus: typing then replaces it and filters
    // right away instead of appending to the old name.
    _focus.addListener(() {
      if (_focus.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _controller.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _controller.text.length,
          );
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final value = w.value;
    final items = w.items;
    final displayName = w.displayName;
    final emptyLabel = w.emptyLabel;
    final onChanged = w.onChanged;
    final suffix = w.suffix;
    final label = w.label;
    // Guard: if value is not in items, treat as null.
    final T? effectiveValue = (value != null && items.contains(value))
        ? value
        : null;
    final sorted = [...items]
      ..sort(
        (a, b) => displayName(
          a,
        ).toLowerCase().compareTo(displayName(b).toLowerCase()),
      );
    final typed = _controller.text.trim();
    final createLabel =
        w.onCreate != null &&
            typed.isNotEmpty &&
            !items.any(
              (i) => displayName(i).toLowerCase() == typed.toLowerCase(),
            )
        ? 'Neu anlegen: „$typed“'
        : null;
    final entries = <DropdownMenuEntry<T?>>[
      if (emptyLabel.isNotEmpty)
        DropdownMenuEntry<T?>(value: null, label: emptyLabel)
      else if (createLabel != null)
        DropdownMenuEntry<T?>(
          value: null,
          label: createLabel,
          leadingIcon: const Icon(Icons.add, size: 18),
        ),
      for (final item in sorted)
        DropdownMenuEntry<T?>(
          value: item,
          label: displayName(item),
          leadingIcon: w.leadingIcon?.call(item),
        ),
    ];
    final selectedLabel = effectiveValue == null
        ? emptyLabel
        : displayName(effectiveValue as T);

    // Fork: type right in the field to filter (no separate popup), regular
    // weight, same height as the other compact fields.
    return LayoutBuilder(
      builder: (context, box) => DropdownMenu<T?>(
        menuController: w.menuController,
        controller: _controller,
        focusNode: _focus,
        initialSelection: effectiveValue,
        label: Text(label),
        // Nothing left to pick: say how to make a new one.
        hintText: w.onCreate != null && items.isEmpty
            ? 'Namen tippen zum Neuanlegen'
            : null,
        enabled: onChanged != null,
        enableFilter: true,
        enableSearch: true,
        requestFocusOnTap: true,
        width: box.maxWidth,
        menuHeight: 280,
        textStyle: Theme.of(context).textTheme.bodyLarge,
        trailingIcon: suffix,
        // App field style (white fill, rounded), compact like the others.
        inputDecorationTheme: Theme.of(context).inputDecorationTheme.copyWith(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          constraints: const BoxConstraints(maxHeight: 52),
        ),
        // Show everything while the field still holds the current choice;
        // filter only once the user types something else.
        filterCallback: (entries, text) {
          final q = text.trim().toLowerCase();
          if (q.isEmpty || text == selectedLabel) return entries;
          return [
            for (final e in entries)
              if (e.label == createLabel ||
                  (e.value != null && e.label.toLowerCase().contains(q)))
                e,
          ];
        },
        dropdownMenuEntries: entries,
        onSelected: (v) {
          if (v == null && createLabel != null) {
            w.onCreate!(typed);
            // The menu just put "Neu anlegen: …" into the field.
            _controller.clear();
          } else {
            onChanged?.call(v);
          }
        },
      ),
    );
  }
}
