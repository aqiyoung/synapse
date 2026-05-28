import 'package:flutter/material.dart';

class TagChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const TagChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary
              : colorScheme.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? colorScheme.primary
                : colorScheme.outline.withOpacity(0.2),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? Colors.white : colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
