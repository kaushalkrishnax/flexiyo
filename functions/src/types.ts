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
  /** Server-assigned Signal device id (integer, never reused). */
  id: number;
  user_id: string;
  /** Stable client-generated installation identifier. */
  installation_id: string;
  legacy_device_id: string | null;
  registration_id: number;
  identity_key: string;
  signed_pre_key_id: number;
  signed_pre_key_public: string;
  signed_pre_key_signature: string;
  status: DeviceStatus;
  created_at: number;
  last_seen_at: number | null;
  revoked_at: number | null;
}

export type DeviceStatus = 'active' | 'pending' | 'disabled' | 'logged_out';

export interface PreKeyRow {
  id: string;
  device_id: number;
  key_id: number;
  public_key: string;
  consumed_at: number | null;
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
  /** Legacy single-payload column. NULL for new multi-device sends. */
  encrypted_payload: string | null;
  message_type: string;
  reply_to_id: string | null;
  version: number;
  is_unsent: number;
  created_at: number;
  expires_at: number | null;
  edited_at: number | null;
  system_data: string | null;
  reaction?: string | null;
  // Computed by list queries (not stored columns):
  /** Aggregated across the recipient account's devices (MIN of non-NULL). */
  delivered_at?: number | null;
  /** Aggregated across the recipient account's devices (MAX of non-NULL). */
  read_at?: number | null;
  /** Ciphertext addressed to the requesting device (message_deliveries.payload). */
  device_payload?: string | null;
  /** message_type of the requesting device's delivery row. */
  device_message_type?: string | null;
  is_sent_by_me?: number;
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

/**
 * Authoritative per-device delivery record: one row per (message, recipient
 * device) holding the ciphertext addressed to that device plus its delivery
 * and read state. Sender-side UI aggregates these across devices.
 */
export interface MessageDeliveriesRow {
  id: string;
  message_id: string;
  recipient_device_id: number;
  sender_device_id: number | null;
  payload: string | null;
  message_type: string;
  delivered_at: number | null;
  read_at: number | null;
  created_at: number;
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

/** One ciphertext addressed to a single device (Signal address = userId+deviceId). */
export interface DevicePayload {
  /** Server-assigned integer device id from the target account's bundle list. */
  deviceId: number;
  ciphertext: string;
  /** Session kind used for this specific device; falls back to the message-level type. */
  messageType?: 'signal' | 'prekey';
}

export interface SendMessageBody {
  id: string;
  /**
   * Preferred multi-device contract: one ciphertext per target device
   * (recipient devices MUST all be covered; sender's other devices SHOULD be
   * covered so they can render sent history).
   */
  payloads?: DevicePayload[];
  /**
   * Legacy single-payload contract (pre-multi-device clients). Accepted and
   * replicated to every recipient device's delivery row; the column
   * messages.encrypted_payload is also populated for old readers.
   */
  encryptedPayload?: string;
  messageType: 'signal' | 'prekey';
  recipientId: string;
  replyToId?: string | null;
}

export interface EditMessageBody {
  /** Legacy single-payload edit (old clients). */
  encryptedPayload?: string;
  /** Preferred per-device edit payloads. */
  payloads?: DevicePayload[];
  messageType: 'signal' | 'prekey';
  version: number;
}

export interface RegisterDeviceBody {
  /** Stable installation id generated once per client install. */
  installationId: string;
  identityKey: string;
  registrationId: number;
  signedPreKey: {
    keyId: number;
    publicKey: string;
    signature: string;
  };
  preKeys: Array<{ keyId: number; publicKey: string }>;
  /** Register as 'pending' instead of 'active' (default true → active). */
  activate?: boolean;
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
      senderDeviceId: number | null;
      /** User ids that should be notified (both participants). */
      recipients: string[];
      /**
       * Per-device ciphertexts. Online sessions whose device id matches an
       * entry receive it as `encryptedPayload`; other sessions receive a
       * metadata-only event (encryptedPayload: null) and must refetch.
       */
      payloads: Array<{ deviceId: number; payload: string | null; messageType: string }>;
      /** Legacy single payload for pre-multi-device clients / unattributed sends. */
      encryptedPayload: string | null;
      messageType: string;
      replyToId: string | null;
      createdAt: number;
      expiresAt: number | null;
    }
  | {
      type: 'message_edited';
      messageId: string;
      conversationId: string;
      recipients: string[];
      payloads: Array<{ deviceId: number; payload: string | null; messageType: string }>;
      encryptedPayload: string | null;
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
      type: 'inbox_message';
      conversationId: string;
      senderId: string;
      preview: string;
      lastMessageAt: number;
      isIncoming: boolean;
    }
  | {
      type: 'message_delivered';
      messageId: string;
      recipientId: string;
      recipientDeviceId: number;
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
