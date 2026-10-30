import 'package:flutter/material.dart';

/// Fork: errors show at the top of the screen, away from the thumb zone.
/// Success needs no message at all. Hides itself after a few seconds.
void showErrorBanner(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentMaterialBanner()
    ..showMaterialBanner(MaterialBanner(
      content: Text(message),
      leading: Icon(Icons.error_outline,
          color: Theme.of(context).colorScheme.error),
      actions: [
        TextButton(
          onPressed: messenger.hideCurrentMaterialBanner,
          child: const Text('OK'),
        ),
      ],
    ));
  Future.delayed(const Duration(seconds: 6), () {
    if (messenger.mounted) messenger.hideCurrentMaterialBanner();
  });
}
