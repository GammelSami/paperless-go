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
      expect(find.text('Keine Angabe'), findsOneWidget);
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

      await tester.tap(find.text('Apple')); // open the menu
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

      // Fork: the field opens a search sheet on tap; disabled = no tap.
      final tap = tester.widget<InkWell>(find.byType(InkWell).first);
      expect(tap.onTap, isNull);
    });
  });
}

String _identity(String s) => s;
