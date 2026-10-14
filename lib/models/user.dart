import 'package:flutter/foundation.dart';

/// Represents a user account.
@immutable
class User {
  const User({
    required this.id,
    required this.username,
    this.createdAt,
  });

  final String id;
  final String username;
  final DateTime? createdAt;

  factory User.fromJson(Map<String, dynamic> json) {
    final createdAtValue = json['created_at'];
    DateTime? parsedCreatedAt;

    if (createdAtValue is int) {
      final ts = createdAtValue > 1e12 ? createdAtValue : createdAtValue * 1000;
      parsedCreatedAt = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
    } else if (createdAtValue is String) {
      parsedCreatedAt = DateTime.tryParse(createdAtValue);
    }

    return User(
      id: json['id'] as String? ?? 'unknown-user',
      username: json['username'] as String? ?? 'Unknown user',
      createdAt: parsedCreatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      };

  User copyWith({String? id, String? username, DateTime? createdAt}) {
    return User(
      id: id ?? this.id,
      username: username ?? this.username,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is User && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'User(id: $id, username: $username)';
}
