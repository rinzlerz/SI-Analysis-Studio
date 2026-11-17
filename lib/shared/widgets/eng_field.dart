import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utilities/units.dart';

/// Numeric engineering input with unit suffix, range validation and an
/// optional tooltip. Only valid values are reported through [onChanged];
/// invalid entries are shown as errors and reported via [onValidity]
/// (no silent substitution of defaults, PRD 13).
class EngField extends StatefulWidget {
  const EngField({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.onChanged,
    this.min,
    this.max,
    this.minExclusive = false,
    this.tooltip,
    this.onValidity,
    this.decimals = 4,
    this.enabled = true,
    this.integer = false,
  });

  final String label;

  /// Value in SI units.
  final double value;
  final UnitSpec unit;
  final ValueChanged<double> onChanged;

  /// Bounds in SI units.
  final double? min;
  final double? max;
  final bool minExclusive;
  final String? tooltip;
  final ValueChanged<bool>? onValidity;
  final int decimals;
  final bool enabled;
  final bool integer;

  @override
  State<EngField> createState() => _EngFieldState();
}

class _EngFieldState extends State<EngField> {
  late final TextEditingController _ctrl;
  final _focus = FocusNode();
  String? _error;

  String _fmt(double si) => formatInput(widget.unit.toDisplay(si), maxDecimals: widget.integer ? 0 : widget.decimals);

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _fmt(widget.value));
  }

  @override
  void didUpdateWidget(covariant EngField old) {
    super.didUpdateWidget(old);
    final parsed = double.tryParse(_ctrl.text.trim());
    final shownSi = parsed == null ? null : widget.unit.toSi(parsed);
    final unitChanged = old.unit.factor != widget.unit.factor;
    final externallyChanged = shownSi == null ||
        (widget.value - shownSi).abs() > 1e-9 * (widget.value.abs() + 1e-30) + 1e-18;
    if (unitChanged || (!_focus.hasFocus && externallyChanged && _error == null)) {
      _ctrl.text = _fmt(widget.value);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _range() {
    final u = widget.unit;
    final lo = widget.min == null ? null : formatInput(u.toDisplay(widget.min!));
    final hi = widget.max == null ? null : formatInput(u.toDisplay(widget.max!));
    if (lo != null && hi != null) return '$lo – $hi ${u.label}';
    if (lo != null) return '${widget.minExclusive ? '>' : '≥'} $lo ${u.label}';
    if (hi != null) return '≤ $hi ${u.label}';
    return '';
  }

  void _onText(String text) {
    final t = text.trim().replaceAll(',', '.');
    String? err;
    double? si;
    final v = double.tryParse(t);
    if (t.isEmpty) {
      err = 'Required';
    } else if (v == null || !v.isFinite) {
      err = 'Not a number';
    } else if (widget.integer && v != v.roundToDouble()) {
      err = 'Whole number';
    } else {
      si = widget.unit.toSi(v);
      final lo = widget.min;
      final hi = widget.max;
      if (lo != null && (widget.minExclusive ? si <= lo : si < lo)) err = 'Range ${_range()}';
      if (hi != null && si > hi) err = 'Range ${_range()}';
    }
    final wasValid = _error == null;
    setState(() => _error = err);
    if (err == null && si != null) widget.onChanged(si);
    if (wasValid != (err == null)) widget.onValidity?.call(err == null);
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: _ctrl,
      focusNode: _focus,
      enabled: widget.enabled,
      keyboardType: TextInputType.numberWithOptions(decimal: !widget.integer, signed: (widget.min ?? 0) < 0),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9eE.,+\-]'))],
      style: kNumStyle.copyWith(fontSize: 15),
      decoration: InputDecoration(
        labelText: widget.label,
        suffixText: widget.unit.label,
        errorText: _error,
        errorMaxLines: 2,
        suffixIcon: widget.tooltip == null
            ? null
            : IconButton(
                icon: const Icon(Icons.info_outline, size: 18),
                color: AppColors.textDim,
                tooltip: widget.tooltip,
                onPressed: () => _showHelp(context),
              ),
      ),
      onChanged: _onText,
    );
    return Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: field);
  }

  void _showHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.label),
        content: Text('${widget.tooltip}\n\nAllowed: ${_range().isEmpty ? 'any value' : _range()}'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }
}

/// Two fields side by side on wide screens, stacked on narrow ones.
class FieldRow extends StatelessWidget {
  const FieldRow({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 360) return Column(children: children);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(child: children[i]),
          ],
        ],
      );
    });
  }
}

/// Labelled dropdown styled like the text fields.
class LabeledDropdown<T> extends StatelessWidget {
  const LabeledDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.itemLabel,
    required this.onChanged,
    this.enabled,
  });

  final String label;
  final T value;
  final List<T> items;
  final String Function(T) itemLabel;
  final ValueChanged<T> onChanged;
  final bool Function(T)? enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, contentPadding: const EdgeInsets.fromLTRB(12, 4, 8, 4)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            isDense: true,
            dropdownColor: AppColors.surfaceHigh,
            items: [
              for (final it in items)
                DropdownMenuItem<T>(
                  value: it,
                  enabled: enabled?.call(it) ?? true,
                  child: Text(
                    itemLabel(it),
                    style: TextStyle(color: (enabled?.call(it) ?? true) ? AppColors.text : AppColors.textDim),
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ),
    );
  }
}
