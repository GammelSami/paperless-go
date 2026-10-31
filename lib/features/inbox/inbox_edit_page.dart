import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_error_mapper.dart';
import '../../core/api/api_providers.dart';
import '../../core/design_tokens.dart';
import '../../core/models/correspondent.dart';
import '../../core/models/custom_field.dart';
import '../../core/models/document.dart';
import '../../core/models/document_type.dart';
import '../../core/models/storage_path.dart';
import '../../core/models/tag.dart';
import '../../shared/error_banner.dart';
import '../../shared/format.dart';
import '../../shared/widgets/metadata_dropdown.dart';
import '../../shared/widgets/tag_chip.dart';
import 'inbox_notifier.dart';

/// Fork: quick edit page for every field the AI fills (also when it left one
/// empty), in the card's order, with Paperless' date suggestions under each
/// date field. "OK" saves; accepting stays on the card. A full page (not a
/// sheet), so Android's predictive back gesture animates it.
class InboxEditPage extends ConsumerStatefulWidget {
  const InboxEditPage({super.key, required this.document});

  final Document document;

  @override
  ConsumerState<InboxEditPage> createState() => _InboxEditPageState();
}

class _InboxEditPageState extends ConsumerState<InboxEditPage> {
  late final TextEditingController _title;
  late final TextEditingController _date;
  int? _correspondentId;
  int? _documentTypeId;
  int? _storagePathId;
  late List<int> _tags;
  final Map<int, dynamic> _fieldValues = {};
  final Map<int, TextEditingController> _fieldText = {};

  /// Amount sign per monetary field (true = minus = you pay).
  final Map<int, bool> _negative = {};
  final _typeMenu = MenuController();
  final _categoryMenu = MenuController();
  final _correspondentMenu = MenuController();
  final _tagMenu = MenuController();

  final Map<int, (Offset, bool)> _pointerStarts = {};
  late final Future<List<DateTime>> _suggestedDates;
  bool _saving = false;

  Document get _doc => widget.document;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: _doc.title);
    _date = TextEditingController(
      text: _doc.created != null ? formatDate(_doc.created!) : '',
    );
    _correspondentId = _doc.correspondent;
    _documentTypeId = _doc.documentType;
    _storagePathId = _doc.storagePath;
    _tags = [..._doc.tags];
    for (final f in _doc.customFields) {
      _fieldValues[f.field] = f.value;
    }
    _suggestedDates = ref
        .read(paperlessApiProvider)
        .getSuggestedDates(_doc.id)
        .catchError((Object _) => <DateTime>[]);
  }

  @override
  void dispose() {
    _title.dispose();
    _date.dispose();
    for (final c in _fieldText.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _textFor(int field, String initial) =>
      _fieldText.putIfAbsent(field, () => TextEditingController(text: initial));

  /// Custom fields DocSort can fill (projects/docsort/classify.sh looks them
  /// up by these names). Shown even when empty, so a missed value can be
  /// added right here.
  static const _aiFieldNames = {'Frist', 'Betrag', 'Erledigt'};

  @override
  Widget build(BuildContext context) {
    final correspondents = ref.watch(correspondentsProvider).valueOrNull ?? {};
    final docTypes = ref.watch(documentTypesProvider).valueOrNull ?? {};
    final storagePaths = ref.watch(storagePathsProvider).valueOrNull ?? {};
    final tags = ref.watch(tagsProvider).valueOrNull ?? {};
    final fieldDefs = ref.watch(customFieldsProvider).valueOrNull ?? {};
    final shownTags = _tags.where((id) => !(tags[id]?.isInboxTag ?? false));
    final fields = _shownFields(fieldDefs);
    final amount = fields
        .where((d) => d.name == 'Betrag' && d.dataType == 'monetary')
        .firstOrNull;
    final done = fields
        .where((d) => d.name == 'Erledigt' && d.dataType == 'boolean')
        .firstOrNull;
    final deadline = fields
        .where((d) => d.name == 'Frist' && d.dataType == 'date')
        .firstOrNull;
    const gap = SizedBox(height: Spacing.md);
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Bearbeiten')),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.sm,
            Spacing.lg,
            Spacing.lg,
          ),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: const Text('OK'),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          // Grows with the title, never cut off; no line breaks, so no
          // empty lines (Enter closes the keyboard instead).
          _keepVisible(
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Titel'),
              minLines: 1,
              maxLines: null,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              inputFormatters: [FilteringTextInputFormatter.deny('\n')],
            ),
          ),
          gap,
          _keepVisible(
            MetadataDropdown<StoragePath>(
              menuController: _categoryMenu,
              label: 'Kategorie',
              value: storagePaths[_storagePathId],
              items: storagePaths.values.toList(),
              displayName: (sp) => sp.name,
              onChanged: (sp) => setState(() => _storagePathId = sp?.id),
            ),
            menuController: _categoryMenu,
          ),
          gap,
          _keepVisible(
            MetadataDropdown<Correspondent>(
              menuController: _correspondentMenu,
              label: 'Absender',
              value: correspondents[_correspondentId],
              items: correspondents.values.toList(),
              displayName: (c) => c.name,
              onChanged: (c) => setState(() => _correspondentId = c?.id),
            ),
            menuController: _correspondentMenu,
          ),
          gap,
          Row(
            children: [
              if (amount != null) ...[
                Expanded(
                  child: _keepVisible(
                    _customField(context, amount),
                    ignoreLeadingTap: true,
                  ),
                ),
                const SizedBox(width: Spacing.md),
              ],
              Expanded(
                child: _keepVisible(
                  MetadataDropdown<DocumentType>(
                    menuController: _typeMenu,
                    label: 'Typ',
                    value: docTypes[_documentTypeId],
                    items: docTypes.values.toList(),
                    displayName: (dt) => dt.name,
                    onChanged: (dt) => setState(() => _documentTypeId = dt?.id),
                  ),
                  menuController: _typeMenu,
                ),
              ),
            ],
          ),
          for (final def in fields)
            if (def != amount && def != done && def.dataType != 'date') ...[
              gap,
              _keepVisible(_customField(context, def)),
            ],
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              for (final id in shownTags) _tagChip(context, tags[id], id),
            ],
          ),
          gap,
          Row(
            children: [
              Expanded(
                flex: 15,
                child: _keepVisible(
                  _dateField(
                    context,
                    _date,
                    'Datum',
                    onPicked: (d) => setState(() => _date.text = formatDate(d)),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                flex: 17,
                child: _keepVisible(
                  MetadataDropdown<Tag>(
                    menuController: _tagMenu,
                    key: ValueKey(_tags.length),
                    label: '+ Tag',
                    value: null,
                    emptyLabel: '',
                    items: tags.values
                        .where((t) => !t.isInboxTag && !_tags.contains(t.id))
                        .toList(),
                    displayName: (t) => t.name,
                    leadingIcon: (t) => TagDot(tag: t, size: 20),
                    onChanged: (t) {
                      if (t != null) setState(() => _tags.add(t.id));
                    },
                    onCreate: _createTag,
                  ),
                  menuController: _tagMenu,
                ),
              ),
            ],
          ),
          _suggestions(_date),
          if (deadline != null) ...[
            gap,
            Row(
              children: [
                Expanded(child: _keepVisible(_customField(context, deadline))),
                if (done != null) ...[
                  const SizedBox(width: Spacing.md),
                  _customField(context, done),
                ],
              ],
            ),
            _suggestions(_textFor(deadline.id, _initialDate(deadline.id))),
          ],
          for (final def in fields)
            if (def.dataType == 'date' && def != deadline) ...[
              gap,
              _keepVisible(_customField(context, def)),
              _suggestions(_textFor(def.id, _initialDate(def.id))),
            ],
          if (done != null && deadline == null) ...[
            gap,
            _customField(context, done),
          ],
          // The dropdown needs one menu-height of scroll room while the
          // keyboard is visible. No extra scroll extent remains afterward.
          AnimatedContainer(
            duration: keyboardOpen
                ? Duration.zero
                : const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            height: keyboardOpen ? 280 : 0,
          ),
        ],
      ),
    );
  }

  /// Dropdowns may close when scrolling starts. Reopen after a real tap has
  /// brought the field into view; regular text fields use Flutter's focus
  /// scrolling without changing the scroll extent.
  Widget _keepVisible(
    Widget child, {
    bool ignoreLeadingTap = false,
    MenuController? menuController,
  }) => Builder(
    builder: (fieldContext) {
      if (menuController == null) return child;
      return Listener(
        onPointerDown: (event) {
          _pointerStarts[event.pointer] = (
            event.localPosition,
            menuController.isOpen,
          );
        },
        onPointerCancel: (event) {
          _pointerStarts.remove(event.pointer);
        },
        onPointerUp: (event) {
          final start = _pointerStarts.remove(event.pointer);
          if (start == null || (event.localPosition - start.$1).distance > 8) {
            return;
          }
          if (ignoreLeadingTap && start.$1.dx < 40) return;
          if (start.$2) return;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!fieldContext.mounted) return;
            menuController.close();
            await _waitForKeyboard();
            if (!fieldContext.mounted) return;
            await Scrollable.ensureVisible(
              fieldContext,
              alignment: 0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
            );
            if (fieldContext.mounted) menuController.open();
          });
        },
        child: child,
      );
    },
  );

  Future<void> _waitForKeyboard() async {
    var last = MediaQuery.viewInsetsOf(context).bottom;
    var stableFrames = 0;
    for (var i = 0; i < 40 && mounted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (!mounted) return;
      final inset = MediaQuery.viewInsetsOf(context).bottom;
      stableFrames = inset > 0 && (inset - last).abs() < 1
          ? stableFrames + 1
          : 0;
      if (stableFrames >= 2) return;
      last = inset;
    }
  }

  Future<void> _createTag(String name) async {
    try {
      final tag = await ref.read(paperlessApiProvider).createTag({
        'name': name,
      });
      ref.invalidate(tagsProvider);
      if (mounted) setState(() => _tags.add(tag.id));
    } catch (e) {
      if (!mounted) return;
      showErrorBanner(
        context,
        'Tag anlegen fehlgeschlagen: ${friendlyApiMessage(e)}',
      );
    }
  }

  /// The document's own custom fields plus the empty AI fields, AI fields
  /// first in DocSort's order.
  List<CustomField> _shownFields(Map<int, CustomField> defs) {
    final ids = <int>{
      for (final name in _aiFieldNames)
        ...defs.values.where((d) => d.name == name).map((d) => d.id),
      ..._doc.customFields.map((f) => f.field),
    };
    return [
      for (final id in ids)
        if (defs[id] != null) defs[id]!,
    ];
  }

  String _initialDate(int field) {
    final v = _fieldValues[field];
    final d = v is String ? DateTime.tryParse(v) : null;
    return d != null ? formatDate(d) : '';
  }

  /// Paperless' date suggestions for this document as one-tap chips.
  Widget _suggestions(TextEditingController target) =>
      FutureBuilder<List<DateTime>>(
        future: _suggestedDates,
        builder: (context, snap) {
          final dates = snap.data ?? const [];
          if (dates.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Wrap(
              spacing: Spacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Vorschläge:',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final d in dates)
                  ActionChip(
                    label: Text(formatDate(d)),
                    onPressed: () =>
                        setState(() => target.text = formatDate(d)),
                  ),
              ],
            ),
          );
        },
      );

  /// Tag in its Paperless colour, same look as on the inbox card.
  Widget _tagChip(BuildContext context, Tag? tag, int id) {
    final c = TagChip.colorOf(context, tag);
    final fg = TagChip.textColor(context, c);
    return InputChip(
      label: Text(tag?.name ?? '#$id'),
      labelStyle: TextStyle(color: fg),
      backgroundColor: TagChip.fill(c),
      side: BorderSide(color: TagChip.outline(c), width: TagChip.outlineWidth),
      shape: const StadiumBorder(),
      deleteIconColor: fg,
      onDeleted: () => setState(() => _tags.remove(id)),
    );
  }

  /// Same height as the dropdowns (see MetadataDropdown).
  static InputDecoration _dense(InputDecoration d) => d.copyWith(
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
    prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 36),
  );

  Widget _dateField(
    BuildContext context,
    TextEditingController controller,
    String label, {
    IconData? icon,
    required ValueChanged<DateTime> onPicked,
  }) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.datetime,
      // Tabular digits, like the dates on the card.
      style: TextStyle(
        fontSize: icon == null ? 14 : null,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      decoration: _dense(
        InputDecoration(
          labelText: label,
          hintText: 'TT.MM.JJJJ',
          // The deadline keeps its ! icon; the compact document date needs the space.
          prefixIcon: icon == null ? null : Icon(icon, size: 18),
          suffixIcon: IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.calendar_month_outlined),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: parseDateDe(controller.text) ?? DateTime.now(),
                firstDate: DateTime(1900),
                lastDate: DateTime(2100),
              );
              if (picked != null) onPicked(picked);
            },
          ),
        ),
      ),
    );
  }

  Widget _customField(BuildContext context, CustomField def) {
    final value = _fieldValues[def.id];
    switch (def.dataType) {
      case 'boolean':
        return InkWell(
          onTap: () => setState(() => _fieldValues[def.id] = value != true),
          borderRadius: BorderRadius.circular(Radii.md),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: value == true,
                visualDensity: VisualDensity.compact,
                onChanged: (v) =>
                    setState(() => _fieldValues[def.id] = v ?? false),
              ),
              Text(def.name),
              const SizedBox(width: Spacing.sm),
            ],
          ),
        );
      case 'date':
        final controller = _textFor(def.id, _initialDate(def.id));
        return _dateField(
          context,
          controller,
          def.name,
          icon: Icons.priority_high,
          onPicked: (d) => setState(() => controller.text = formatDate(d)),
        );
      case 'monetary':
        // Sign is a button (tap to flip); the field holds the amount only.
        final negative = _negative.putIfAbsent(
          def.id,
          () => value != null && formatMoney(value).startsWith('-'),
        );
        final shown = value == null
            ? ''
            : formatMoney(
                value,
              ).replaceAll(' €', '').replaceAll('+', '').replaceAll('-', '');
        return TextField(
          controller: _textFor(def.id, shown),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration:
              _dense(
                InputDecoration(labelText: def.name, suffixText: '€'),
              ).copyWith(
                prefixIconConstraints: const BoxConstraints(minHeight: 36),
                prefixIcon: IconButton(
                  tooltip: negative
                      ? 'Minus: du zahlst (tippen für Plus)'
                      : 'Plus: du bekommst (tippen für Minus)',
                  // Tight box: only a small gap to the number.
                  padding: const EdgeInsets.only(left: 14, right: 3),
                  constraints: const BoxConstraints(minHeight: 36),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => setState(() {
                    _negative[def.id] = !negative;
                    _fieldValues.putIfAbsent(def.id, () => null);
                  }),
                  icon: Text(
                    negative ? '−' : '+',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
        );
      case 'string':
      case 'url':
      case 'integer':
      case 'float':
        return TextField(
          controller: _textFor(def.id, value?.toString() ?? ''),
          decoration: _dense(InputDecoration(labelText: def.name)),
        );
      default:
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(def.name),
          subtitle: Text(value?.toString() ?? '—'),
        );
    }
  }

  /// Builds the PATCH body. Returns null and shows a message on bad input.
  Map<String, dynamic>? _patch(Map<int, CustomField> fieldDefs) {
    String? isoDate(String text, String label) {
      if (text.trim().isEmpty) return null;
      final d = parseDateDe(text);
      if (d == null) throw FormatException('$label: bitte als TT.MM.JJJJ');
      return '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
    }

    try {
      final fields = <Map<String, dynamic>>[];
      final onDoc = _doc.customFields.map((f) => f.field).toSet();
      for (final def in _shownFields(fieldDefs)) {
        final id = def.id;
        final text = _fieldText[id]?.text;
        dynamic value = _fieldValues[id];
        if (text != null) {
          switch (def.dataType) {
            case 'date':
              value = isoDate(text, def.name);
            case 'monetary':
              // German input: "1.249,90" → 1249.90 (dots are thousands).
              var t = text.trim().replaceAll(' ', '');
              if (t.contains(',')) {
                t = t.replaceAll('.', '').replaceAll(',', '.');
              }
              if (t.isEmpty) {
                value = null;
              } else {
                final n = double.tryParse(t)?.abs();
                if (n == null) {
                  throw FormatException('${def.name}: keine Zahl');
                }
                final signed = (_negative[id] ?? false) ? -n : n;
                value = 'EUR${signed.toStringAsFixed(2)}';
              }
            case 'integer':
              value = int.tryParse(text.trim());
            case 'float':
              value = double.tryParse(text.trim().replaceAll(',', '.'));
            default:
              value = text;
          }
        }
        // An AI field the document never had stays off unless filled in.
        final touched =
            _fieldValues.containsKey(id) ||
            (text != null && text.trim().isNotEmpty);
        if (!onDoc.contains(id) && !touched) continue;
        fields.add({'field': id, 'value': value});
      }
      final created = isoDate(_date.text, 'Datum');
      return {
        'title': _title.text.trim(),
        'correspondent': _correspondentId,
        'document_type': _documentTypeId,
        'storage_path': _storagePathId,
        'tags': _tags,
        'custom_fields': fields,
        if (created != null) 'created': created,
      };
    } on FormatException catch (e) {
      showErrorBanner(context, e.message);
      return null;
    }
  }

  /// Saves only; accepting stays the ✓ on the card.
  Future<void> _save() async {
    final fieldDefs = ref.read(customFieldsProvider).valueOrNull ?? {};
    final data = _patch(fieldDefs);
    if (data == null) return;
    setState(() => _saving = true);
    try {
      await ref.read(paperlessApiProvider).updateDocument(_doc.id, data);
      ref.invalidate(inboxNotifierProvider);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showErrorBanner(
        context,
        'Speichern fehlgeschlagen: ${friendlyApiMessage(e)}',
      );
    }
  }
}
