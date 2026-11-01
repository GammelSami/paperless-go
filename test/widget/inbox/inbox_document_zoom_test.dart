import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_go/features/inbox/inbox_document_zoom.dart';

Future<MemoryImage> _pageImage() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 200, 400),
    Paint()..color = Colors.white,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(200, 400);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final provider = MemoryImage(bytes.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return provider;
}

void main() {
  testWidgets('short document ends directly above metadata', (tester) async {
    final provider = (await tester.runAsync(_pageImage))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 250,
            height: 580,
            child: Column(
              children: [
                Flexible(
                  child: InboxDocumentZoom(
                    image: provider,
                    fitToImageHeight: true,
                    child: Image(image: provider, fit: BoxFit.fitWidth),
                  ),
                ),
                const Text('Title and correspondent'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => precacheImage(
        provider,
        tester.element(find.byType(InboxDocumentZoom)),
      ),
    );
    await tester.pumpAndSettle();
    final page = tester.getRect(find.byType(Image).first);
    final info = tester.getRect(find.text('Title and correspondent'));
    expect(page.height, 500);
    expect(info.top, page.bottom);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinch persists, pans, resets, then resumes paging and swiping', (
    tester,
  ) async {
    final provider = (await tester.runAsync(_pageImage))!;
    var pages = 0;
    var swipes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GestureDetector(
              onPanUpdate: (_) => swipes++,
              child: SizedBox(
                width: 250,
                height: 180,
                child: GestureDetector(
                  onTap: () => pages++,
                  child: InboxDocumentZoom(
                    image: provider,
                    child: Image(
                      image: provider,
                      fit: BoxFit.fitWidth,
                      alignment: Alignment.topCenter,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => precacheImage(
        provider,
        tester.element(find.byType(InboxDocumentZoom)),
      ),
    );
    await tester.pumpAndSettle();
    final preview = find.byType(InboxDocumentZoom);
    final center = tester.getCenter(preview);
    final source = tester.getRect(preview);
    final restingPage = source.topLeft & Size(source.width, source.width * 2);
    final zoom = find.byKey(const ValueKey('document-zoom-image'));
    final dim = find.byKey(const ValueKey('document-zoom-dim'));

    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(pages, 1);
    await tester.timedDrag(
      preview,
      const Offset(60, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(swipes, greaterThan(0));
    expect(zoom, findsNothing);
    final previousSwipes = swipes;

    final first = await tester.startGesture(
      center - const Offset(30, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 2,
    );
    await tester.pump();
    expect(zoom, findsOneWidget);
    expect(
      tester.getRect(zoom),
      restingPage,
      reason: 'The very first zoom frame must match the inline document.',
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester.getRect(zoom),
      restingPage,
      reason: 'Holding still must not run an opening animation.',
    );
    await first.moveBy(const Offset(-2, 0));
    await second.moveBy(const Offset(2, 0));
    await tester.pump();
    const firstScale = 64 / 60;
    final anchored =
        (center - (center - restingPage.topLeft) * firstScale) &
        (restingPage.size * firstScale);
    expect(
      tester.getRect(zoom),
      rectMoreOrLessEquals(anchored),
      reason: 'Even the first small movement must follow the fingers exactly.',
    );
    final held = tester.getRect(zoom);
    expect(
      tester.widget<ColoredBox>(dim).color.a,
      closeTo(0.65 * (firstScale - 1) * 2, 0.001),
      reason: 'The edge reveal now advances at half its previous rate.',
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.getRect(zoom), held);
    await first.moveBy(const Offset(-25, 0));
    await second.moveBy(const Offset(25, 0));
    await tester.pump();
    await first.moveBy(const Offset(-20, 0));
    await second.moveBy(const Offset(20, 0));
    await tester.pump();
    final enlarged = tester.getRect(zoom);
    expect(enlarged.width, greaterThan(250));
    expect(enlarged.height / enlarged.width, closeTo(2, 0.001));
    expect(dim, findsOneWidget);
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(zoom), enlarged);
    final clip = find
        .ancestor(of: zoom, matching: find.byType(ClipRRect))
        .first;
    expect(tester.getRect(clip), const Rect.fromLTWH(0, 0, 800, 600));
    expect(pages, 1);
    expect(swipes, previousSwipes);

    await tester.dragFrom(const Offset(400, 300), const Offset(40, 50));
    await tester.pumpAndSettle();
    expect(tester.getRect(zoom).topLeft, isNot(enlarged.topLeft));
    expect(tester.getRect(zoom).size, enlarged.size);
    expect(swipes, previousSwipes);

    final inwardFirst = await tester.startGesture(
      const Offset(320, 300),
      pointer: 3,
    );
    final inwardSecond = await tester.startGesture(
      const Offset(480, 300),
      pointer: 4,
    );
    await inwardFirst.moveTo(const Offset(390, 300));
    await tester.pump();
    await inwardSecond.moveTo(const Offset(440, 300));
    await tester.pump();
    expect(zoom, findsOneWidget);
    expect(
      tester.widget<ColoredBox>(dim).color.a,
      0.65,
      reason: 'Further gestures must not shrink the full-screen zoom viewport.',
    );
    await inwardSecond.moveTo(const Offset(410, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      zoom,
      findsOneWidget,
      reason: 'Reaching minimum zoom springs back instead of disappearing.',
    );
    await tester.pumpAndSettle();
    expect(
      zoom,
      findsNothing,
      reason: 'Minimum zoom exits without needing a tap or lifting fingers.',
    );
    await inwardFirst.up();
    await inwardSecond.up();
    await tester.pumpAndSettle();
    expect(pages, 1);

    final againFirst = await tester.startGesture(
      center - const Offset(30, 0),
      pointer: 5,
    );
    final againSecond = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 6,
    );
    await againFirst.moveBy(const Offset(-30, 0));
    await againSecond.moveBy(const Offset(30, 0));
    await againFirst.up();
    await againSecond.up();
    await tester.pumpAndSettle();
    expect(zoom, findsOneWidget);

    await tester.tapAt(const Offset(400, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(zoom, findsOneWidget);
    await tester.pumpAndSettle();
    expect(zoom, findsNothing);
    expect(dim, findsNothing);
    expect(pages, 1);
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(pages, 2);
    expect(tester.takeException(), isNull);
  });
}
