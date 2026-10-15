export interface Env {
  DB: D1Database;
  CHAT_ROOM: DurableObjectNamespace;
  JWT_SECRET: string;
  CORS_ORIGIN: string;
  /// GitHub `owner/repo` publishing release APKs. Defaults to kaushalkrishnax/flexiyo.
  UPDATE_GITHUB_REPO?: string;
}

export interface JWTPayload {
  sub: string;       // user ID
  username: string;
  jti: string;       // unique token ID (for revocation)
  iat: number;
  exp: number;
}

export interface AuthenticatedRequest extends Request {
  user: JWTPayload;
}

export interface UserRow {
  id: string;
  username: string;
  password_hash: string;
  email?: string | null;
  google_id?: string | null;
  email_verified?: number;
  created_at: number;
}

export interface TokenRevocationRow {
  jti: string;
  user_id: string;
  expires_at: number;
}

export interface DeviceRow {
  id: string;
  user_id: string;
  device_id: string;
  registration_id: number;
  identity_key: string;
  signed_pre_key_id: number;
  signed_pre_key_public: string;
  signed_pre_key_signature: string;
  created_at: number;
}

export interface PreKeyRow {
  id: string;
  user_id: string;
  key_id: number;
  public_key: string;
  used: number;
  created_at: number;
}

export interface ConversationRow {
  id: string;
  user_a_id: string;
  user_b_id: string;
  initiated_by_id: string | null;
  request_status: 'pending' | 'accepted' | 'rejected';
  disappearing_timer: number;
  created_at: number;
  last_message_at: number | null;
}

export interface MessageRow {
  id: string;
  conversation_id: string;
  sender_id: string;
  encrypted_payload: string | null;
  message_type: string;
  reply_to_id: string | null;
  version: number;
  is_unsent: number;
  created_at: number;
  expires_at: number | null;
  edited_at: number | null;
  system_data: string | null;
  delivered_at: number | null;
  read_at: number | null;
  reaction?: string | null;
}

export interface MessageReactionRow {
  id: string;
  message_id: string;
  conversation_id: string;
  user_id: string;
  emoji: string;
  created_at: number;
  updated_at: number;
}

export interface MessageDeliveryRow {
  id: string;
  message_id: string;
  recipient_id: string;
  delivered_at: number | null;
  read_at: number | null;
}

export interface LocalDeletionRow {
  id: string;
  user_id: string;
  message_id: string;
  deleted_at: number;
}

export interface RegisterBody {
  username: string;
  password: string;
}

export interface LoginBody {
  username: string;
  password: string;
}

export interface CreateConversationBody {
  participantId: string;
}

export interface DisappearingTimerBody {
  timer: 0 | 30 | 60 | 300 | 3600 | 86400 | 604800;
}

export interface SendMessageBody {
  id: string;
  encryptedPayload: string;
  messageType: 'signal' | 'prekey';
  recipientId: string;
  replyToId?: string | null;
}

export interface EditMessageBody {
  encryptedPayload: string;
  messageType: 'signal' | 'prekey';
  version: number;
}

export interface RegisterDeviceBody {
  deviceId: string;
  identityKey: string;
  registrationId: number;
  signedPreKey: {
    keyId: number;
    publicKey: string;
    signature: string;
  };
  preKeys: Array<{ keyId: number; publicKey: string }>;
}

export interface ReplenishPreKeysBody {
  preKeys: Array<{ keyId: number; publicKey: string }>;
}

export interface AuthResponse {
  token: string;
  user: {
    id: string;
    username: string;
    createdAt: number;
  };
}

export interface ConversationResponse {
  id: string;
  conversant: {
    id: string;
    username: string;
  };
  disappearingTimer: number;
  requestStatus: 'pending' | 'accepted' | 'rejected';
  initiatedById: string | null;
  lastMessageAt: number | null;
  unreadCount: number;
  createdAt: number;
  isPinned?: boolean;
  isMuted?: boolean;
  isRestricted?: boolean;
}

export interface MessageResponse {
  id: string;
  conversationId: string;
  senderId: string;
  encryptedPayload: string | null;
  messageType: string;
  replyToId: string | null;
  version: number;
  isUnsent: boolean;
  createdAt: number;
  expiresAt: number | null;
  editedAt: number | null;
  systemData: string | null;
  reaction?: string | null;
}

export type DOEvent =
  | {
      type: 'new_message';
      messageId: string;
      conversationId: string;
      senderId: string;
      encryptedPayload: string;
      messageType: string;
      replyToId: string | null;
      createdAt: number;
      expiresAt: number | null;
    }
  | {
      type: 'message_edited';
      messageId: string;
      conversationId: string;
      encryptedPayload: string;
      messageType: string;
      version: number;
      editedAt: number;
    }
  | {
      type: 'message_unsent';
      messageId: string;
      conversationId: string;
      unsentAt: number;
    }
  | {
      type: 'message_reaction';
      conversationId: string;
      messageId: string;
      userId: string;
      emoji: string | null;
      reaction: string | null;
    }
  | {
      type: 'message_delivered';
      messageId: string;
      recipientId: string;
      deliveredAt: number;
    }
  | {
      type: 'messages_read';
      conversationId: string;
      readBy: string;
      readAt: number;
    }
  | {
      type: 'disappearing_timer_changed';
      conversationId: string;
      timer: number;
      changedBy: string;
    }
  | {
      type: 'typing_start';
      userId: string;
    }
  | {
      type: 'typing_stop';
      userId: string;
    }
  | {
      type: 'request_accepted' | 'request_rejected';
      conversationId: string;
      changedBy: string;
    };
