import 'package:flutter/material.dart';
import 'package:simple_live_app/app/app_style.dart';

class FilterButton extends StatefulWidget {
  final bool selected;
  final String text;
  final Function()? onTap;
  const FilterButton({
    this.selected = false,
    required this.text,
    this.onTap,
    Key? key,
  }) : super(key: key);

  @override
  State<FilterButton> createState() => _FilterButtonState();
}

class _FilterButtonState extends State<FilterButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;

    Color bgColor;
    Color textColor;
    BorderSide borderSide;

    if (widget.selected) {
      bgColor = primaryColor.withOpacity(isDark ? 0.25 : 0.12);
      textColor = primaryColor;
      borderSide = BorderSide(color: primaryColor.withOpacity(0.4), width: 1.2);
    } else if (_isHovered) {
      bgColor = isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.05);
      textColor = theme.textTheme.bodyMedium?.color ?? Colors.black87;
      borderSide = BorderSide(color: Colors.grey.withOpacity(0.3), width: 1);
    } else {
      bgColor = isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.03);
      textColor = isDark ? const Color(0xffa0a0a5) : const Color(0xff6e6e73);
      borderSide = BorderSide(color: Colors.grey.withOpacity(0.18), width: 1);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.fromBorderSide(borderSide),
            boxShadow: widget.selected
                ? [
                    BoxShadow(
                      color: primaryColor.withOpacity(0.15),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    )
                  ]
                : null,
          ),
          child: Text(
            widget.text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: widget.selected ? FontWeight.w600 : FontWeight.normal,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}
