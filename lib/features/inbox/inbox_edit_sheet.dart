import 'package:flutter/material.dart';
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
import '../../shared/widgets/tag_picker_sheet.dart';
import 'inbox_notifier.dart';

/// Fork: quick edit for every field the AI fills (also when it left one
/// empty), in the card's order, with Paperless' date suggestions under each
/// date field. "OK" saves; accepting stays on the card.
class InboxEditSheet extends ConsumerStatefulWidget {
  const InboxEditSheet({super.key, required this.document});

  final Document document;

  @override
  ConsumerState<InboxEditSheet> createState() => _InboxEditSheetState();
}

class _InboxEditSheetState extends ConsumerState<InboxEditSheet> {
  late final TextEditingController _title;
  late final TextEditingController _date;
  int? _correspondentId;
  int? _documentTypeId;
  int? _storagePathId;
  late List<int> _tags;
  final Map<int, dynamic> _fieldValues = {};
  final Map<int, TextEditingController> _fieldText = {};
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
    const gap = SizedBox(height: Spacing.md);

    // Same order as the inbox card: title, category / correspondent, type,
    // amount-like fields, tags, then the dates.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.all(Spacing.lg),
          children: [
            Text('Bearbeiten', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Spacing.lg),
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Titel'),
              maxLines: null,
            ),
            gap,
            MetadataDropdown<StoragePath>(
              label: 'Kategorie',
              value: storagePaths[_storagePathId],
              items: storagePaths.values.toList(),
              displayName: (sp) => sp.name,
              onChanged: (sp) => setState(() => _storagePathId = sp?.id),
            ),
            gap,
            MetadataDropdown<Correspondent>(
              label: 'Absender',
              value: correspondents[_correspondentId],
              items: correspondents.values.toList(),
              displayName: (c) => c.name,
              onChanged: (c) => setState(() => _correspondentId = c?.id),
            ),
            gap,
            MetadataDropdown<DocumentType>(
              label: 'Typ',
              value: docTypes[_documentTypeId],
              items: docTypes.values.toList(),
              displayName: (dt) => dt.name,
              onChanged: (dt) => setState(() => _documentTypeId = dt?.id),
            ),
            for (final def in fields)
              if (def.dataType != 'date') ...[gap, _customField(context, def)],
            gap,
            Text('Tags', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: Spacing.xs),
            Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                for (final id in shownTags) _tagChip(context, tags[id], id),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Tag'),
                  onPressed: () => _pickTag(
                    context,
                    tags.values
                        .where((t) => !t.isInboxTag && !_tags.contains(t.id))
                        .toList(),
                  ),
                ),
              ],
            ),
            gap,
            _dateField(
              context,
              _date,
              'Dokumentdatum',
              onPicked: (d) => setState(() => _date.text = formatDate(d)),
            ),
            _suggestions(_date),
            for (final def in fields)
              if (def.dataType == 'date') ...[
                gap,
                _customField(context, def),
                _suggestions(_textFor(def.id, _initialDate(def.id))),
              ],
            const SizedBox(height: Spacing.lg),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
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
    final ink = Theme.of(context).colorScheme.onSurface;
    final c =
        TagChip.parseColor(tag?.colour) ??
        Theme.of(context).colorScheme.secondary;
    return InputChip(
      label: Text(tag?.name ?? '#$id'),
      labelStyle: TextStyle(color: Color.lerp(ink, c, 0.3)),
      backgroundColor: c.withValues(alpha: 0.08),
      side: BorderSide(color: c.withValues(alpha: 0.55), width: 1.2),
      shape: const StadiumBorder(),
      deleteIconColor: Color.lerp(ink, c, 0.3),
      onDeleted: () => setState(() => _tags.remove(id)),
    );
  }

  Widget _dateField(
    BuildContext context,
    TextEditingController controller,
    String label, {
    required ValueChanged<DateTime> onPicked,
  }) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.datetime,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'TT.MM.JJJJ',
        suffixIcon: IconButton(
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
    );
  }

  Widget _customField(BuildContext context, CustomField def) {
    final value = _fieldValues[def.id];
    switch (def.dataType) {
      case 'boolean':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(def.name),
          value: value == true,
          onChanged: (v) => setState(() => _fieldValues[def.id] = v),
        );
      case 'date':
        final controller = _textFor(def.id, _initialDate(def.id));
        return _dateField(
          context,
          controller,
          def.name,
          onPicked: (d) => setState(() => controller.text = formatDate(d)),
        );
      case 'monetary':
        final shown = value == null
            ? ''
            : formatMoney(value).replaceAll(' €', '').replaceAll('+', '');
        return TextField(
          controller: _textFor(def.id, shown),
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            labelText: def.name,
            suffixText: '€',
            helperText: 'Minus = du zahlst, ohne Minus = du bekommst',
          ),
        );
      case 'string':
      case 'url':
      case 'integer':
      case 'float':
        return TextField(
          controller: _textFor(def.id, value?.toString() ?? ''),
          decoration: InputDecoration(labelText: def.name),
        );
      default:
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(def.name),
          subtitle: Text(value?.toString() ?? '—'),
        );
    }
  }

  void _pickTag(BuildContext context, List<Tag> available) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => TagPickerSheet(
        tags: available,
        onSelected: (tag) {
          setState(() => _tags.add(tag.id));
          Navigator.pop(sheetContext);
        },
      ),
    );
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
              if (t.contains(','))
                t = t.replaceAll('.', '').replaceAll(',', '.');
              if (t.isEmpty) {
                value = null;
              } else {
                final n = double.tryParse(t);
                if (n == null) {
                  throw FormatException('${def.name}: keine Zahl');
                }
                value = 'EUR${n.toStringAsFixed(2)}';
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
