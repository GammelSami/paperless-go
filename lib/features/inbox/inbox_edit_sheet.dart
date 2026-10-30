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
import '../../shared/widgets/tag_picker_sheet.dart';
import 'inbox_notifier.dart';

/// Fork: one sheet to edit every field the AI filled in, including the date
/// (German input, picker, and Paperless' own date suggestions as chips).
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
        text: _doc.created != null ? formatDate(_doc.created!) : '');
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

  @override
  Widget build(BuildContext context) {
    final correspondents = ref.watch(correspondentsProvider).valueOrNull ?? {};
    final docTypes = ref.watch(documentTypesProvider).valueOrNull ?? {};
    final storagePaths = ref.watch(storagePathsProvider).valueOrNull ?? {};
    final tags = ref.watch(tagsProvider).valueOrNull ?? {};
    final fieldDefs = ref.watch(customFieldsProvider).valueOrNull ?? {};
    final shownTags = _tags.where((id) => !(tags[id]?.isInboxTag ?? false));

    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom),
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
            const SizedBox(height: Spacing.md),
            _dateField(context, _date, 'Datum', onPicked: (d) {
              setState(() => _date.text = formatDate(d));
            }),
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
                      Text('Vorschläge:',
                          style: Theme.of(context).textTheme.bodySmall),
                      for (final d in dates)
                        ActionChip(
                          label: Text(formatDate(d)),
                          onPressed: () =>
                              setState(() => _date.text = formatDate(d)),
                        ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: Spacing.md),
            MetadataDropdown<Correspondent>(
              label: 'Absender',
              value: correspondents[_correspondentId],
              items: correspondents.values.toList(),
              displayName: (c) => c.name,
              onChanged: (c) => setState(() => _correspondentId = c?.id),
            ),
            const SizedBox(height: Spacing.md),
            MetadataDropdown<DocumentType>(
              label: 'Typ',
              value: docTypes[_documentTypeId],
              items: docTypes.values.toList(),
              displayName: (dt) => dt.name,
              onChanged: (dt) => setState(() => _documentTypeId = dt?.id),
            ),
            const SizedBox(height: Spacing.md),
            MetadataDropdown<StoragePath>(
              label: 'Kategorie',
              value: storagePaths[_storagePathId],
              items: storagePaths.values.toList(),
              displayName: (sp) => sp.name,
              onChanged: (sp) => setState(() => _storagePathId = sp?.id),
            ),
            const SizedBox(height: Spacing.md),
            Text('Tags', style: Theme.of(context).textTheme.bodySmall),
            Wrap(
              spacing: Spacing.xs,
              children: [
                for (final id in shownTags)
                  InputChip(
                    label: Text(tags[id]?.name ?? '#$id'),
                    onDeleted: () => setState(() => _tags.remove(id)),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Tag'),
                  onPressed: () => _pickTag(context, tags.values
                      .where((t) => !t.isInboxTag && !_tags.contains(t.id))
                      .toList()),
                ),
              ],
            ),
            for (final f in _doc.customFields)
              if (fieldDefs[f.field] != null)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.md),
                  child: _customField(context, fieldDefs[f.field]!),
                ),
            const SizedBox(height: Spacing.lg),
            FilledButton(
              onPressed: _saving ? null : () => _save(accept: true),
              child: const Text('Speichern & annehmen'),
            ),
            const SizedBox(height: Spacing.xs),
            OutlinedButton(
              onPressed: _saving ? null : () => _save(accept: false),
              child: const Text('Nur speichern'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateField(BuildContext context, TextEditingController controller,
      String label,
      {required ValueChanged<DateTime> onPicked}) {
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
        final parsed = value is String ? DateTime.tryParse(value) : null;
        final initial = parsed != null ? formatDate(parsed) : '';
        final controller = _textFor(def.id, initial);
        return _dateField(context, controller, def.name,
            onPicked: (d) => setState(() => controller.text = formatDate(d)));
      case 'monetary':
        final shown = value == null
            ? ''
            : formatMoney(value).replaceAll(' €', '').replaceAll('+', '');
        return TextField(
          controller: _textFor(def.id, shown),
          keyboardType: const TextInputType.numberWithOptions(
              decimal: true, signed: true),
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
      for (final f in _doc.customFields) {
        final def = fieldDefs[f.field];
        final text = _fieldText[f.field]?.text;
        dynamic value = _fieldValues[f.field];
        if (def != null && text != null) {
          switch (def.dataType) {
            case 'date':
              value = isoDate(text, def.name);
            case 'monetary':
              final t = text.trim().replaceAll(' ', '').replaceAll(',', '.');
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
        fields.add({'field': f.field, 'value': value});
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

  Future<void> _save({required bool accept}) async {
    final fieldDefs = ref.read(customFieldsProvider).valueOrNull ?? {};
    final data = _patch(fieldDefs);
    if (data == null) return;
    setState(() => _saving = true);
    try {
      if (accept) {
        final tags = await ref.read(tagsProvider.future);
        data['tags'] = _tags.where((id) => !(tags[id]?.isInboxTag ?? false)).toList();
      }
      await ref.read(paperlessApiProvider).updateDocument(_doc.id, data);
      ref.invalidate(inboxNotifierProvider);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showErrorBanner(
          context, 'Speichern fehlgeschlagen: ${friendlyApiMessage(e)}');
    }
  }
}
