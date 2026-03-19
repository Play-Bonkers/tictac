import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

import 'topic_controller.dart';

class TicTacMessageActionItem {
  final IconData icon;
  final String label;
  final Color? color;
  final void Function(types.Message message) onPressed;

  const TicTacMessageActionItem({
    required this.icon,
    required this.label,
    this.color,
    required this.onPressed,
  });
}

class TicTacMessageActionsOptions {
  final bool enabled;
  final bool showDelete;
  final IconData deleteIcon;
  final String deleteLabel;
  final Color deleteColor;
  final Color? backgroundColor;
  final BorderRadius borderRadius;
  final double elevation;
  final Color barrierColor;
  final bool Function(types.Message message)? filter;
  final List<TicTacMessageActionItem>? extraActions;
  final Widget Function(
    BuildContext context,
    types.Message message,
    VoidCallback dismiss,
  )? builder;

  const TicTacMessageActionsOptions({
    this.enabled = true,
    this.showDelete = true,
    this.deleteIcon = Icons.delete,
    this.deleteLabel = 'Delete',
    this.deleteColor = Colors.red,
    this.backgroundColor,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.elevation = 8.0,
    this.barrierColor = Colors.black54,
    this.filter,
    this.extraActions,
    this.builder,
  });
}

void showTicTacMessageActions({
  required BuildContext context,
  required types.Message message,
  required TopicController controller,
  required String currentUserId,
  required TicTacMessageActionsOptions options,
}) {
  // Filter: default is own messages only
  final shouldShow =
      options.filter?.call(message) ?? (message.author.id == currentUserId);
  if (!shouldShow) return;

  // Skip typing placeholders
  if (TopicController.isTypingPlaceholder(message)) return;

  // Full custom builder
  if (options.builder != null) {
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => entry.remove(),
        child: Material(
          color: options.barrierColor,
          child: Center(
            child: options.builder!(ctx, message, () => entry.remove()),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(entry);
    return;
  }

  // Build action items
  final actions = <_ActionEntry>[];

  if (options.extraActions != null) {
    for (final action in options.extraActions!) {
      actions.add(_ActionEntry(
        icon: action.icon,
        label: action.label,
        color: action.color,
        onTap: () => action.onPressed(message),
      ));
    }
  }

  if (options.showDelete) {
    actions.add(_ActionEntry(
      icon: options.deleteIcon,
      label: options.deleteLabel,
      color: options.deleteColor,
      onTap: () => controller.deleteMessage(message.id),
    ));
  }

  if (actions.isEmpty) return;

  // Get message row position
  final renderBox = context.findRenderObject() as RenderBox;
  final rowOffset = renderBox.localToGlobal(Offset.zero);
  final rowSize = renderBox.size;
  final overlay = Overlay.of(context);
  final screenSize = MediaQuery.of(context).size;

  final isOwnMessage = message.author.id == currentUserId;

  const menuWidth = 160.0;
  const itemHeight = 44.0;
  final menuHeight = actions.length * itemHeight + 16;
  const edgePadding = 8.0;

  double left;
  if (isOwnMessage) {
    left = rowOffset.dx + rowSize.width - menuWidth - 16;
  } else {
    left = rowOffset.dx + 48;
  }
  left = left.clamp(edgePadding, screenSize.width - menuWidth - edgePadding);

  double top;
  final spaceBelow = screenSize.height - (rowOffset.dy + rowSize.height);
  if (spaceBelow >= menuHeight + edgePadding) {
    top = rowOffset.dy + rowSize.height + 4;
  } else {
    top = rowOffset.dy - menuHeight - 4;
  }
  top = top.clamp(edgePadding, screenSize.height - menuHeight - edgePadding);

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => entry.remove(),
            child: ColoredBox(color: options.barrierColor),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: options.backgroundColor ?? Colors.grey[900],
            borderRadius: options.borderRadius,
            elevation: options.elevation,
            child: ClipRRect(
              borderRadius: options.borderRadius,
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          color: Colors.white12,
                        ),
                      InkWell(
                        onTap: () {
                          entry.remove();
                          actions[i].onTap();
                        },
                        child: Container(
                          width: menuWidth,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                actions[i].icon,
                                size: 20,
                                color: actions[i].color,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                actions[i].label,
                                style: TextStyle(
                                  color: actions[i].color ?? Colors.white,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  overlay.insert(entry);
}

class _ActionEntry {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const _ActionEntry({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
  });
}
