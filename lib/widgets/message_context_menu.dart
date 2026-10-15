import 'package:flexiyo/models/message.dart';
import 'package:flexiyo/widgets/app_popup_menu.dart';
import 'package:flutter/material.dart';

/// Legacy wrapper for message long-press popup forwarding to AppPopupMenu.
class MessageContextMenu {
  const MessageContextMenu._();

  static Future<void> show(
    BuildContext context, {
    required bool isMine,
    required Message message,
    required String myUserId,
    required bool isEditEligible,
    required VoidCallback onReply,
    required VoidCallback onCopy,
    VoidCallback? onEdit,
    VoidCallback? onUnsend,
    required VoidCallback onDeleteForMe,
    VoidCallback? onSelectMode,
    required Offset tapPosition,
    ValueChanged<String>? onReact,
  }) {
    return AppPopupMenu.showMessageMenu(
      context,
      isMine: isMine,
      message: message,
      tapPosition: tapPosition,
      onReply: onReply,
      onCopy: onCopy,
      onUnsend: onUnsend,
      onDeleteForMe: onDeleteForMe,
      onReact: onReact,
    );
  }
}
