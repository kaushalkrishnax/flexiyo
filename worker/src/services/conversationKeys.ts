export const ENCRYPTION_VERSION_CONVERSATION_KEY = 2;
export const XCHACHA20_NONCE_BYTES = 24;
export const POLY1305_TAG_BYTES = 16;
export const MAX_CIPHERTEXT_BYTES = 64 * 1024;
const MAX_KEY_BYTES = 64;

export interface ConversationEnvelope {
  ciphertext: string;
  nonce: string;
  authTag: string;
  keyEpoch: number;
}

export type EnvelopeValidation =
  | { ok: true; envelope: ConversationEnvelope }
  | { ok: false; error: string };

function decodeBase64(value: string): Uint8Array | null {
  try {
    return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
  } catch {
    return null;
  }
}

/**
 * Validates the v2 wire envelope without inspecting plaintext. Nonce and tag
 * lengths are fixed by XChaCha20-Poly1305; a mismatch is a protocol error, not
 * something the server may paper over.
 */
export function validateConversationEnvelope(input: Record<string, unknown>): EnvelopeValidation {
  const ciphertext = input.ciphertext;
  const nonce = input.nonce;
  const authTag = input.authTag;
  const keyEpoch = input.keyEpoch;

  if (typeof ciphertext !== 'string' || ciphertext.length === 0) {
    return { ok: false, error: 'missing_ciphertext' };
  }
  if (typeof nonce !== 'string' || typeof authTag !== 'string') {
    return { ok: false, error: 'missing_nonce_or_tag' };
  }
  if (!Number.isInteger(keyEpoch) || (keyEpoch as number) <= 0) {
    return { ok: false, error: 'invalid_key_epoch' };
  }

  const cipherBytes = decodeBase64(ciphertext);
  const nonceBytes = decodeBase64(nonce);
  const tagBytes = decodeBase64(authTag);
  if (!cipherBytes || cipherBytes.length === 0 || cipherBytes.length > MAX_CIPHERTEXT_BYTES) {
    return { ok: false, error: 'invalid_ciphertext' };
  }
  if (!nonceBytes || nonceBytes.length !== XCHACHA20_NONCE_BYTES) {
    return { ok: false, error: 'invalid_nonce' };
  }
  if (!tagBytes || tagBytes.length !== POLY1305_TAG_BYTES) {
    return { ok: false, error: 'invalid_auth_tag' };
  }

  return {
    ok: true,
    envelope: {
      ciphertext,
      nonce,
      authTag,
      keyEpoch: keyEpoch as number,
    },
  };
}

/** Wrapped-key envelope used for multi-device provisioning. */
export function validateKeyEnvelope(input: Record<string, unknown>): string | null {
  const fields = ['ephemeralPublicKey', 'nonce', 'ciphertext', 'mac'];
  for (const field of fields) {
    if (typeof input[field] !== 'string' || (input[field] as string).length === 0) {
      return `invalid_${field}`;
    }
  }
  const ephemeral = decodeBase64(input.ephemeralPublicKey as string);
  const nonce = decodeBase64(input.nonce as string);
  const ciphertext = decodeBase64(input.ciphertext as string);
  const mac = decodeBase64(input.mac as string);
  if (!ephemeral || ephemeral.length !== 32) return 'invalid_ephemeral_public_key';
  if (!nonce || nonce.length !== XCHACHA20_NONCE_BYTES) return 'invalid_nonce';
  if (!ciphertext || ciphertext.length === 0 || ciphertext.length > MAX_CIPHERTEXT_BYTES) {
    return 'invalid_ciphertext';
  }
  if (!mac || mac.length !== POLY1305_TAG_BYTES) return 'invalid_mac';
  return null;
}

export function isConversationKeyMessage(body: unknown): boolean {
  return (
    typeof body === 'object' &&
    body !== null &&
    (body as { encryptionVersion?: unknown }).encryptionVersion ===
      ENCRYPTION_VERSION_CONVERSATION_KEY
  );
}

export function validatePublicKey(value: unknown): string | null {
  if (typeof value !== 'string' || value.length === 0) return null;
  const bytes = decodeBase64(value);
  if (!bytes || bytes.length !== 32 || bytes.length > MAX_KEY_BYTES) return null;
  return value;
}
