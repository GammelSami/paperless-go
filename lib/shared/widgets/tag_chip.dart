import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../core/models/tag.dart';

class TagChip extends StatelessWidget {
  final Tag tag;
  const TagChip({super.key, required this.tag});

  @override
  Widget build(BuildContext context) {
    final c = colorOf(context, tag);
    return Semantics(
      label: '${tag.name} tag',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: fill(c),
          border: Border.all(color: outline(c), width: outlineWidth),
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(
          tag.name,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: textColor(context, c),
            fontWeight: FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  // Fork: one subtle tag look everywhere (Sam liked it on the inbox card):
  // outline in the tag colour, a faint tint inside, ink text with a touch of
  // the tag colour, so every tag stays readable.
  static const outlineWidth = 1.2;

  static Color colorOf(BuildContext context, Tag? tag) =>
      parseColor(tag?.colour) ?? Theme.of(context).colorScheme.secondary;

  static Color fill(Color c) => c.withValues(alpha: 0.08);

  static Color outline(Color c) => c.withValues(alpha: 0.55);

  static Color textColor(BuildContext context, Color c) =>
      Color.lerp(Theme.of(context).colorScheme.onSurface, c, 0.3)!;

  /// Compute a contrasting text color for a given background color.
  static Color contrastColor(Color bg) {
    return bg.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;
  }

  static Color? parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final cleaned = hex.replaceFirst('#', '');
    try {
      int r, g, b, a = 0xFF;
      if (cleaned.length == 6) {
        r = int.parse(cleaned.substring(0, 2), radix: 16);
        g = int.parse(cleaned.substring(2, 4), radix: 16);
        b = int.parse(cleaned.substring(4, 6), radix: 16);
      } else if (cleaned.length == 8) {
        a = int.parse(cleaned.substring(0, 2), radix: 16);
        r = int.parse(cleaned.substring(2, 4), radix: 16);
        g = int.parse(cleaned.substring(4, 6), radix: 16);
        b = int.parse(cleaned.substring(6, 8), radix: 16);
      } else {
        return null;
      }
      return Color.fromARGB(a, r, g, b);
    } catch (_) {
      return null;
    }
  }
}

/// Fork: small round marker in the subtle tag look (lists, pickers).
class TagDot extends StatelessWidget {
  const TagDot({super.key, required this.tag, this.size = 24});

  final Tag tag;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = TagChip.colorOf(context, tag);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: TagChip.fill(c),
        border: Border.all(color: TagChip.outline(c), width: 2),
      ),
    );
  }
}

class TagOverflowChip extends StatelessWidget {
  final int count;
  const TagOverflowChip({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$count more tags',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: 3,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(
          '+$count',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
