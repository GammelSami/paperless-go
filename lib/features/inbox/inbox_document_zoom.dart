import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A persistent pinch preview above the card's clipping and navigation.
class InboxDocumentZoom extends StatefulWidget {
  const InboxDocumentZoom({
    super.key,
    required this.image,
    required this.child,
    this.enabled = true,
  });

  final ImageProvider image;
  final Widget child;
  final bool enabled;

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
  Rect _screen = Rect.zero;
  Rect _viewport = Rect.zero;
  Offset _focalPoint = Offset.zero;
  Offset _overlayOrigin = Offset.zero;
  double _fitWidth = 1;
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
      _viewport = Rect.fromLTRB(
        16,
        padding.top + 16,
        _screen.right - 16,
        _screen.bottom - padding.bottom - 16,
      );
      final size = applyBoxFit(
        BoxFit.contain,
        _imageSize!,
        _viewport.size,
      ).destination;
      _page = Alignment.center.inscribe(size, _viewport);
      _fitWidth = size.width;
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
      _fitWidth * 6,
    );
    final scale = width / _gesturePage.width;
    final focalPoint = details.focalPoint - _overlayOrigin;
    final topLeft = focalPoint - (_focalPoint - _gesturePage.topLeft) * scale;
    final height = _gesturePage.height * scale;
    // Keep every edge reachable without losing the page outside the screen.
    final x = width <= _viewport.width
        ? _viewport.center.dx - width / 2
        : topLeft.dx.clamp(_viewport.right - width, _viewport.left);
    final y = height <= _viewport.height
        ? _viewport.center.dy - height / 2
        : topLeft.dy.clamp(_viewport.bottom - height, _viewport.top);
    setState(() {
      _page = Rect.fromLTWH(x, y, width, height);
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
        final target =
            _source.topLeft &
            Size(_source.width, _source.width / _imageSize!.aspectRatio);
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
        final clip = Rect.lerp(_screen, _source, progress.clamp(0, 1))!;
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
                      color: Colors.black.withValues(
                        alpha: 0.65 * (1 - progress.clamp(0, 1)),
                      ),
                    ),
                  ),
                  Positioned.fromRect(
                    rect: clip,
                    child: ClipRect(
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
        child: Opacity(opacity: _visible ? 0 : 1, child: widget.child),
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
