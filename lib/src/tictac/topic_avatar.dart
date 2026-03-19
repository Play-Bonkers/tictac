import 'package:flutter/material.dart';

import 'user_avatar.dart';
import 'models/topic_type.dart';

/// Data class describing a topic member for avatar rendering.
class TicTacTopicAvatarMember {
  const TicTacTopicAvatarMember({
    required this.userId,
    this.displayName,
    this.imageUrl,
    this.isOnline = false,
  });

  final String userId;
  final String? displayName;
  final String? imageUrl;
  final bool isOnline;
}

/// A composite avatar widget for the topic list.
///
/// Rendering modes:
/// - **DIRECT (1 member):** Single avatar at full [size] with presence dot.
/// - **GROUP 2-4 members:** Overlapping avatars, each at `size * 0.65`.
/// - **GROUP 5+ members:** First 3 avatars stacked + a "+N" badge.
class TicTacTopicAvatar extends StatelessWidget {
  const TicTacTopicAvatar({
    super.key,
    required this.topicType,
    required this.members,
    this.size = 48,
    this.userAvatarBuilder,
  });

  final TopicType topicType;
  final List<TicTacTopicAvatarMember> members;
  final double size;
  final Widget Function(String userId, bool isOnline)? userAvatarBuilder;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return SizedBox(width: size, height: size);
    }

    if (topicType == TopicType.direct || members.length == 1) {
      return _buildSingle(members.first);
    }

    if (members.length <= 4) {
      return _buildSmallGroup();
    }

    return _buildLargeGroup();
  }

  Widget _buildSingle(TicTacTopicAvatarMember member) {
    if (userAvatarBuilder != null) {
      return SizedBox(
        width: size,
        height: size,
        child: userAvatarBuilder!(member.userId, member.isOnline),
      );
    }
    return TicTacUserAvatar(
      displayName: member.displayName,
      imageUrl: member.imageUrl,
      isOnline: member.isOnline,
      size: size,
    );
  }

  /// 2-4 members: overlapping avatars arranged diagonally.
  Widget _buildSmallGroup() {
    final avatarSize = size * 0.65;
    final offset = size - avatarSize;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < members.length && i < 4; i++)
            Positioned(
              left: i.isEven ? 0 : offset,
              top: i < 2 ? 0 : offset,
              child: _buildMemberAvatar(members[i], avatarSize),
            ),
        ],
      ),
    );
  }

  /// 5+ members: first 3 stacked + "+N" badge.
  Widget _buildLargeGroup() {
    final avatarSize = size * 0.55;
    final remaining = members.length - 3;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: _buildMemberAvatar(members[0], avatarSize),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: _buildMemberAvatar(members[1], avatarSize),
          ),
          Positioned(
            left: 0,
            bottom: 0,
            child: _buildMemberAvatar(members[2], avatarSize),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: avatarSize,
              height: avatarSize,
              decoration: const BoxDecoration(
                color: Color(0xFFBDBDBD),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                '+$remaining',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: avatarSize * 0.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemberAvatar(TicTacTopicAvatarMember member, double avatarSize) {
    if (userAvatarBuilder != null) {
      return SizedBox(
        width: avatarSize,
        height: avatarSize,
        child: userAvatarBuilder!(member.userId, member.isOnline),
      );
    }
    return TicTacUserAvatar(
      displayName: member.displayName,
      imageUrl: member.imageUrl,
      isOnline: member.isOnline,
      size: avatarSize,
    );
  }
}
