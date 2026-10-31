import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_go/core/api/api_providers.dart';
import 'package:paperless_go/core/api/paperless_api.dart';
import 'package:paperless_go/core/models/document.dart';
import 'package:paperless_go/core/models/document_type.dart';
import 'package:paperless_go/core/models/tag.dart';
import 'package:paperless_go/features/inbox/inbox_edit_page.dart';

class _NoNetworkApi extends PaperlessApi {
  _NoNetworkApi() : super(Dio());

  @override
  Future<List<DateTime>> getSuggestedDates(int documentId) async => [];
}

void main() {
  testWidgets('first dropdown tap scrolls its menu above the keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    final types = {
      for (var i = 1; i <= 5; i++)
        i: DocumentType(id: i, name: 'Type $i', slug: 'type-$i'),
    };
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          paperlessApiProvider.overrideWith((ref) => _NoNetworkApi()),
          tagsProvider.overrideWith((ref) async => {}),
          correspondentsProvider.overrideWith((ref) async => {}),
          documentTypesProvider.overrideWith((ref) async => types),
          storagePathsProvider.overrideWith((ref) async => {}),
          customFieldsProvider.overrideWith((ref) async => {}),
        ],
        child: const MaterialApp(
          home: InboxEditPage(
            document: Document(
              id: 1,
              title: 'A long title that needs several lines in the editor',
              documentType: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();

    final typeField = find.byType(DropdownMenu<DocumentType?>);
    final before = tester.getTopLeft(typeField).dy;
    await tester.tap(typeField);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(typeField).dy, lessThan(before));
    expect(tester.getBottomLeft(find.text('Type 5').last).dy, lessThan(400));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final keyboardExtent = scroll.position.maxScrollExtent;
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    await tester.pumpAndSettle();
    expect(scroll.position.maxScrollExtent, lessThan(keyboardExtent - 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('many tags scroll while OK stays at the bottom', (tester) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final tags = {
      for (var i = 1; i <= 24; i++)
        i: Tag(id: i, name: 'Tag $i', slug: 'tag-$i'),
    };
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          paperlessApiProvider.overrideWith((ref) => _NoNetworkApi()),
          tagsProvider.overrideWith((ref) async => tags),
          correspondentsProvider.overrideWith((ref) async => {}),
          documentTypesProvider.overrideWith((ref) async => {}),
          storagePathsProvider.overrideWith((ref) async => {}),
          customFieldsProvider.overrideWith((ref) async => {}),
        ],
        child: MaterialApp(
          home: InboxEditPage(
            document: Document(
              id: 1,
              title: 'Long tag list',
              tags: tags.keys.toList(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final ok = find.widgetWithText(FilledButton, 'OK');
    final bottom = tester.getBottomLeft(ok).dy;
    expect(bottom, greaterThan(600));
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(ok).dy, bottom);
    expect(find.text('Datum'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(ok).dy, bottom);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final dateField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Datum',
    );
    await tester.drag(dateField, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(
      scroll.position.pixels,
      lessThanOrEqualTo(scroll.position.maxScrollExtent),
    );
    final settledOffset = scroll.position.pixels;
    await tester.pump(const Duration(seconds: 2));
    expect(scroll.position.pixels, settledOffset);
    expect(tester.takeException(), isNull);
  });
}
