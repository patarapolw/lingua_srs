import 'package:flutter/material.dart';

/// A switch flanked by icons for its two sides, e.g. moon (o ) sun.
/// Off is the leading side, on is the trailing side.
class IconSwitch extends StatelessWidget {
  final IconData leading;
  final IconData trailing;
  final bool value;
  final ValueChanged<bool> onChanged;

  const IconSwitch({
    super.key,
    required this.leading,
    required this.trailing,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(leading, size: 20, color: value ? scheme.outline : scheme.primary),
        Switch(value: value, onChanged: onChanged),
        Icon(
          trailing,
          size: 20,
          color: value ? scheme.primary : scheme.outline,
        ),
      ],
    );
  }
}
