import 'package:flutter/material.dart';

/// A user avatar with an online/offline presence indicator dot.
///
/// Renders a [CircleAvatar] (with image or initials) and a small
/// colored dot overlaid at the bottom-right corner:
/// - Green when [isOnline] is true
/// - Grey when [isOnline] is false
class TicTacUserAvatar extends StatelessWidget {
  const TicTacUserAvatar({
    super.key,
    this.displayName,
    this.imageUrl,
    required this.isOnline,
    this.size = 32,
  });

  final String? displayName;
  final String? imageUrl;
  final bool isOnline;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dotSize = size * 0.3;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          CircleAvatar(
            radius: size / 2,
            backgroundImage:
                imageUrl != null ? NetworkImage(imageUrl!) : null,
            backgroundColor: const Color(0xFF6C63FF),
            child: imageUrl == null
                ? Text(
                    _initials(displayName),
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: size * 0.4,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : null,
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                color: isOnline
                    ? const Color(0xFF4CAF50)
                    : const Color(0xFF9E9E9E),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white,
                  width: dotSize * 0.15,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _initials(String? name) {
    if (name == null || name.isEmpty) return '';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return parts.first[0].toUpperCase();
  }
}
