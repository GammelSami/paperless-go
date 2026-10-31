import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_go/shared/widgets/metadata_dropdown.dart';

void main() {
  group('MetadataDropdown', () {
    testWidgets('renders None when the value is not in items (no crash)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MetadataDropdown<String>(
              label: 'Fruit',
              value: 'Cherry', // absent from items
              items: const ['Apple', 'Banana'],
              displayName: (s) => s,
              onChanged: (_) {},
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'Keine Angabe');
    });

    testWidgets('selecting an item invokes onChanged', (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MetadataDropdown<String>(
              label: 'Fruit',
              value: 'Apple',
              items: const ['Apple', 'Banana'],
              displayName: (s) => s,
              onChanged: (s) => selected = s,
            ),
          ),
        ),
      );

      await tester.tap(find.byType(TextField)); // open the menu
      await tester.pumpAndSettle();
      await tester.tap(find.text('Banana').last); // pick a different item
      await tester.pumpAndSettle();

      expect(selected, 'Banana');
    });

    testWidgets('is disabled when onChanged is null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MetadataDropdown<String>(
              label: 'Fruit',
              value: 'Apple',
              items: ['Apple', 'Banana'],
              displayName: _identity,
              onChanged: null,
            ),
          ),
        ),
      );

      // Fork: an inline-searchable DropdownMenu; disabled = not enabled.
      final menu = tester.widget<DropdownMenu<String?>>(
        find.byType(DropdownMenu<String?>),
      );
      expect(menu.enabled, isFalse);
    });
  });
}

String _identity(String s) => s;
