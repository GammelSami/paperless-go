import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';

/// A persistent pinch preview above the card's clipping and navigation.
class InboxDocumentZoom extends StatefulWidget {
  const InboxDocumentZoom({
    super.key,
    required this.image,
    required this.child,
    this.enabled = true,
    this.fit = BoxFit.fitWidth,
  });

  final ImageProvider image;
  final Widget child;
  final bool enabled;
  final BoxFit fit;

  @override
  State<InboxDocumentZoom> createState() => _InboxDocumentZoomState();
}

class _InboxDocumentZoomState extends State<InboxDocumentZoom>
    with SingleTickerProviderStateMixin {
  final _overlay = OverlayPortalController();
  late final _return = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..addListener(() => setState(() {}));
  ImageStream? _stream;
  late final _imageListener = ImageStreamListener((info, _) {
    _imageSize = Size(
      info.image.width.toDouble(),
      info.image.height.toDouble(),
    );
    info.dispose();
  }, onError: (Object _, StackTrace? __) {});
  Size? _imageSize;
  Rect _page = Rect.zero;
  Rect _gesturePage = Rect.zero;
  Rect _source = Rect.zero;
  Rect _sourcePage = Rect.zero;
  Rect _screen = Rect.zero;
  Offset _focalPoint = Offset.zero;
  Offset _overlayOrigin = Offset.zero;
  double _fitWidth = 1;
  double _reveal = 0;
  double _cornerReveal = 0;
  bool _visible = false;
  bool _returning = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(InboxDocumentZoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image ||
        oldWidget.enabled != widget.enabled) {
      _resolveImage();
    }
  }

  void _resolveImage() {
    _stream?.removeListener(_imageListener);
    _imageSize = null;
    if (!widget.enabled) return;
    _stream = widget.image.resolve(createLocalImageConfiguration(context))
      ..addListener(_imageListener);
  }

  void _start(ScaleStartDetails details) {
    if (_returning || _imageSize == null) return;
    if (!_visible) {
      if (details.pointerCount < 2) return;
      final source = context.findRenderObject()! as RenderBox;
      final overlay =
          Overlay.of(context, rootOverlay: true).context.findRenderObject()!
              as RenderBox;
      _overlayOrigin = overlay.localToGlobal(Offset.zero);
      _source =
          (source.localToGlobal(Offset.zero) - _overlayOrigin) & source.size;
      _screen = Offset.zero & overlay.size;
      final padding = MediaQuery.viewPaddingOf(context);
      final viewport = Rect.fromLTRB(
        16,
        padding.top + 16,
        _screen.right - 16,
        _screen.bottom - padding.bottom - 16,
      );
      final size = applyBoxFit(
        BoxFit.contain,
        _imageSize!,
        viewport.size,
      ).destination;
      // Match the inline image's actual scale and alignment, including a
      // thumbnail cropped with BoxFit.cover. Never reposition it on entry.
      final fitted = applyBoxFit(widget.fit, _imageSize!, _source.size);
      final imageScale = fitted.destination.width / fitted.source.width;
      _sourcePage = Alignment.topCenter.inscribe(
        _imageSize! * imageScale,
        _source,
      );
      _page = _sourcePage;
      _fitWidth = math.min(size.width, _sourcePage.width);
      _reveal = 0;
      _cornerReveal = 0;
      setState(() => _visible = true);
      _overlay.show();
    }
    _gesturePage = _page;
    _focalPoint = details.focalPoint - _overlayOrigin;
  }

  void _update(ScaleUpdateDetails details) {
    if (!_visible || _returning) return;
    final width = (_gesturePage.width * details.scale).clamp(
      _fitWidth,
      _sourcePage.width * 6,
    );
    if (width <= _fitWidth && (width < _page.width || details.scale < 1)) {
      _reset();
      return;
    }
    final shrinking = width < _page.width;
    final scale = width / _gesturePage.width;
    final focalPoint = details.focalPoint - _overlayOrigin;
    final topLeft = focalPoint - (_focalPoint - _gesturePage.topLeft) * scale;
    final height = _gesturePage.height * scale;
    setState(() {
      // The focal point stays attached to the same point on the document.
      _cornerReveal = shrinking
          ? math.min(
              _cornerReveal,
              ((width - _fitWidth) / _sourcePage.width).clamp(0, 1),
            )
          : math.max(
              _cornerReveal,
              math
                  .max(
                    (details.scale - 1).abs(),
                    (focalPoint - _focalPoint).distance / 320,
                  )
                  .clamp(0, 1),
            );
      // Recentring or edge clamping here would move it away from the fingers.
      _page = topLeft & Size(width, height);
      // Unclip and dim as the fingers move, without a timed entry animation.
      _reveal = shrinking
          ? math.min(
              _reveal,
              ((width - _fitWidth) / _sourcePage.width * 2).clamp(0, 1),
            )
          : math.max(
              _reveal,
              math
                  .max(
                    (details.scale - 1).abs() * 2,
                    (focalPoint - _focalPoint).distance / 160,
                  )
                  .clamp(0, 1),
            );
    });
  }

  Future<void> _reset() async {
    if (!_visible || _returning) return;
    setState(() => _returning = true);
    await _return.forward(from: 0).orCancel.catchError((Object _) {});
    if (!mounted) return;
    _overlay.hide();
    setState(() {
      _visible = false;
      _returning = false;
    });
    _return.reset();
  }

  @override
  void dispose() {
    _stream?.removeListener(_imageListener);
    _return.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_visible,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _reset();
    },
    child: OverlayPortal(
      overlayLocation: OverlayChildLocation.rootOverlay,
      controller: _overlay,
      overlayChildBuilder: (context) {
        final progress = Curves.easeOutBack.transform(_return.value);
        final target = _sourcePage;
        final interpolated = Rect.lerp(_page, target, progress)!;
        // Limit spring overshoot even when returning from maximum zoom.
        final width = interpolated.width.clamp(
          target.width * 0.9,
          double.infinity,
        );
        final page = Rect.fromCenter(
          center: interpolated.center,
          width: width,
          height: width / _imageSize!.aspectRatio,
        );
        final reveal = _reveal * (1 - progress.clamp(0, 1));
        final clip = Rect.lerp(_source, _screen, reveal)!;
        return Positioned.fill(
          child: Semantics(
            label: 'Dokument vergrößert. Tippen zum Zurücksetzen.',
            button: true,
            onTap: _reset,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _reset,
              onScaleStart: _start,
              onScaleUpdate: _update,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(
                      key: const ValueKey('document-zoom-dim'),
                      color: Colors.black.withValues(alpha: 0.65 * reveal),
                    ),
                  ),
                  Positioned.fromRect(
                    rect: clip,
                    child: Opacity(
                      opacity: _reveal == 0 ? 0 : 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(
                            Radii.xl *
                                (1 -
                                    _cornerReveal * (1 - progress.clamp(0, 1))),
                          ),
                        ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fromRect(
                              rect: page.shift(-clip.topLeft),
                              child: Image(
                                key: const ValueKey('document-zoom-image'),
                                image: widget.image,
                                fit: BoxFit.fill,
                                gaplessPlayback: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      child: RawGestureDetector(
        gestures: {
          if (widget.enabled)
            _PinchRecognizer:
                GestureRecognizerFactoryWithHandlers<_PinchRecognizer>(
                  _PinchRecognizer.new,
                  (recognizer) => recognizer
                    ..onStart = _start
                    ..onUpdate = _update,
                ),
        },
        child: Opacity(
          opacity: _visible && _reveal > 0 ? 0 : 1,
          child: widget.child,
        ),
      ),
    ),
  );
}

/// Leave a single finger to the card swipe; claim only a real pinch.
class _PinchRecognizer extends ScaleGestureRecognizer {
  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    // Claim both pointers before the card's pan reaches its drag threshold.
    if (event is PointerDownEvent && pointerCount >= 2) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void resolve(GestureDisposition disposition) {
    if (disposition == GestureDisposition.accepted && pointerCount < 2) return;
    super.resolve(disposition);
  }
}
