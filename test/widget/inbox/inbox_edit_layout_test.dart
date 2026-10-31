import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_go/core/api/api_providers.dart';
import 'package:paperless_go/core/api/paperless_api.dart';
import 'package:paperless_go/core/models/document.dart';
import 'package:paperless_go/core/models/tag.dart';
import 'package:paperless_go/features/inbox/inbox_edit_page.dart';

class _NoNetworkApi extends PaperlessApi {
  _NoNetworkApi() : super(Dio());

  @override
  Future<List<DateTime>> getSuggestedDates(int documentId) async => [];
}

void main() {
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
    await tester.drag(find.text('Datum'), const Offset(0, -400));
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
