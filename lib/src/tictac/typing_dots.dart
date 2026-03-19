import 'package:flutter/widgets.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

class TicTacTypingDotsOptions {
  final double dotSize;
  final Color dotColor;
  final double dotSpacing;
  final Duration animationDuration;
  final double bounceHeight;
  final EdgeInsets padding;
  final bool enabled;
  final Widget Function(BuildContext context, types.CustomMessage message)?
      builder;

  const TicTacTypingDotsOptions({
    this.dotSize = 6.0,
    this.dotColor = const Color(0xff615e6e),
    this.dotSpacing = 4.0,
    this.animationDuration = const Duration(milliseconds: 500),
    this.bounceHeight = 0.9,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    this.enabled = true,
    this.builder,
  });
}

class TicTacTypingDots extends StatefulWidget {
  final TicTacTypingDotsOptions options;

  const TicTacTypingDots({super.key, required this.options});

  @override
  State<TicTacTypingDots> createState() => _TicTacTypingDotsState();
}

class _TicTacTypingDotsState extends State<TicTacTypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _first;
  late Animation<Offset> _second;
  late Animation<Offset> _third;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.options.animationDuration,
    )..repeat();

    _buildAnimations();
  }

  @override
  void didUpdateWidget(TicTacTypingDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.options.animationDuration != widget.options.animationDuration ||
        oldWidget.options.bounceHeight != widget.options.bounceHeight) {
      _controller.duration = widget.options.animationDuration;
      _buildAnimations();
      _controller.repeat();
    }
  }

  void _buildAnimations() {
    final h = widget.options.bounceHeight;
    _first = _bounce(const Interval(0.0, 1.0), h);
    _second = _bounce(const Interval(0.3, 1.0), h);
    _third = _bounce(const Interval(0.45, 1.0), h);
  }

  Animation<Offset> _bounce(Interval interval, double height) {
    return TweenSequence<Offset>([
      TweenSequenceItem(
        tween: Tween(begin: Offset.zero, end: Offset(0, -height)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween(begin: Offset(0, -height), end: Offset.zero),
        weight: 50,
      ),
    ]).animate(CurvedAnimation(parent: _controller, curve: interval));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opts = widget.options;

    return Padding(
      padding: opts.padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _dot(_first, opts),
          SizedBox(width: opts.dotSpacing),
          _dot(_second, opts),
          SizedBox(width: opts.dotSpacing),
          _dot(_third, opts),
        ],
      ),
    );
  }

  Widget _dot(Animation<Offset> animation, TicTacTypingDotsOptions opts) {
    return SlideTransition(
      position: animation,
      child: Container(
        width: opts.dotSize,
        height: opts.dotSize,
        decoration: BoxDecoration(
          color: opts.dotColor,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
