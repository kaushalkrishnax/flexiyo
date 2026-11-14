export interface Env {
  DB: D1Database;
  TURSO_DB_URL?: string;
  TURSO_DB_TOKEN?: string;
  CHAT_ROOM: DurableObjectNamespace;
  JWT_SECRET: string;
  CORS_ORIGIN: string;
  BREVO_API_KEY?: string;
  BREVO_SENDER_EMAIL?: string;
  BREVO_SENDER_NAME?: string;
  UPDATE_GITHUB_REPO?: string;
  GITHUB_TOKEN?: string;
  FCM_SERVICE_ACCOUNT?: string;
  MEDIA: R2Bucket;
  MEDIA_TTL_DAYS?: string;
  MEDIA_DAILY_UPLOAD_BYTES?: string;
  MEDIA_DAILY_DOWNLOAD_BYTES?: string;
  MEDIA_MAX_UPLOAD_BYTES?: string;
  GOOGLE_OAUTH_CLIENT_ID?: string;
}

export type ViewPolicy = 'once' | 'twice' | 'unlimited';

export interface MediaRow {
  id: string;
  conversation_id: string;
  sender_id: string;
  kind: 'image' | 'voice';
  view_policy: ViewPolicy;
  size: number;
  mime_type: string | null;
  r2_key: string;
  duration_ms: number | null;
  created_at: number;
  expires_at: number;
  consumed: number;
  message_id?: string | null;
}

export interface MediaDto {
  id: string;
  kind: 'image' | 'voice';
  viewPolicy: ViewPolicy;
  size: number;
  durationMs: number | null;
  createdAt: number;
}

export interface JWTPayload {
  sub: string;
  username: string;
  jti: string;
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
  id: number;
  user_id: string;
  installation_id: string;
  status: DeviceStatus;
  created_at: number;
  last_seen_at: number | null;
  revoked_at: number | null;
  identity_public_key: string | null;
}

export type DeviceStatus = 'active' | 'pending' | 'disabled' | 'logged_out';

export interface ConversationRow {
  id: string;
  user_a_id: string;
  user_b_id: string;
  initiated_by_id: string | null;
  request_status: 'pending' | 'accepted' | 'rejected';
  disappearing_timer: number;
  created_at: number;
  last_message_at: number | null;
  last_message_sender_id: string | null;
  key_epoch: number;
  key_rotation_required: number;
}

export interface ConversationUserStateRow {
  conversation_id: string;
  user_id: string;
  unread_count: number;
  last_read_at: number | null;
  peer_seen_at: number | null;
}

export interface MessageRow {
  id: string;
  conversation_id: string;
  sender_id: string;
  sender_device_id?: number | null;
  message_type: string;
  reply_to_id: string | null;
  version: number;
  is_unsent: number;
  created_at: number;
  expires_at: number | null;
  edited_at: number | null;
  system_data: string | null;
  reaction?: string | null;
  ciphertext: string | null;
  nonce: string | null;
  auth_tag: string | null;
  key_epoch: number | null;
  delivered_at: number | null;
  read_at: number | null;
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

export interface ConversationKeyMessageBody {
  id: string;
  encryptionVersion: 2;
  ciphertext: string;
  nonce: string;
  authTag: string;
  keyEpoch: number;
  recipientId: string;
  mediaId?: string | null;
  replyToId?: string | null;
}

export interface ConversationKeyEditBody {
  encryptionVersion: 2;
  ciphertext: string;
  nonce: string;
  authTag: string;
  keyEpoch: number;
  version: number;
}

export interface KeyEnvelopeBody {
  recipientDeviceId: number;
  ephemeralPublicKey: string;
  nonce: string;
  ciphertext: string;
  mac: string;
}

export interface PairingSessionRow {
  id: string;
  user_id: string;
  initiator_device_id: number;
  initiator_ephemeral_public: string;
  status: 'pending' | 'joined' | 'approved' | 'cancelled' | 'expired';
  joined_installation_id: string | null;
  joined_identity_public: string | null;
  joined_ephemeral_public: string | null;
  joined_nonce: string | null;
  joined_ciphertext: string | null;
  joined_mac: string | null;
  approved_device_id: number | null;
  created_at: number;
  expires_at: number;
  approved_at: number | null;
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
  senderDeviceId: number | null;
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
  ciphertext?: string | null;
  nonce?: string | null;
  authTag?: string | null;
  keyEpoch?: number | null;
  encryptionVersion: 2;
  deliveredAt?: number | null;
  readAt?: number | null;
}

export type DOEvent =
  | {
      type: 'new_message';
      messageId: string;
      conversationId: string;
      senderId: string;
      senderDeviceId: number | null;
      recipients: string[];
      encryptionVersion: 2;
      ciphertext: string;
      nonce: string;
      authTag: string;
      keyEpoch: number;
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
      encryptionVersion: 2;
      ciphertext: string;
      nonce: string;
      authTag: string;
      keyEpoch: number;
      messageType: string;
      version: number;
      editedAt: number;
    }
  | {
      type: 'message_deleted';
      messageId: string;
      conversationId: string;
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
      recipientDeviceId?: number;
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
