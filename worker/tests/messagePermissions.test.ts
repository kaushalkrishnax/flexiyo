import { describe, expect, it } from 'vitest';
import {
  getMessageEditDenial,
  getMessageSendDenial,
} from '../src/services/messagePermissions.js';

const message = {
  senderId: 'alice',
  userId: 'alice',
  isUnsent: false,
  createdAt: 1_000,
  now: 1_899,
};

describe('message edit permissions', () => {
  it('allows the sender to edit before the 15-minute deadline', () => {
    expect(getMessageEditDenial(message)).toBeNull();
  });

  it('expires exactly at 15 minutes from original creation', () => {
    expect(getMessageEditDenial({ ...message, now: 1_900 })).toBe('expired');
  });

  it('rejects edits by a different account', () => {
    expect(getMessageEditDenial({ ...message, userId: 'bob' })).toBe('not_sender');
  });

  it('rejects edits to unsent messages', () => {
    expect(getMessageEditDenial({ ...message, isUnsent: true })).toBe('unsent');
  });

  it('rejects messages with a future server timestamp', () => {
    expect(getMessageEditDenial({ ...message, createdAt: 1_900, now: 1_899 })).toBe('expired');
  });
});

describe('pending message request send permissions', () => {
  const pendingRequest = {
    requestStatus: 'pending' as const,
    initiatedById: 'alice',
    userId: 'alice',
    hasExistingMessage: false,
  };

  it('allows the initiator to send the first request message', () => {
    expect(getMessageSendDenial(pendingRequest)).toBeNull();
  });

  it('blocks the recipient until acceptance', () => {
    expect(getMessageSendDenial({ ...pendingRequest, userId: 'bob' })).toBe(
      'recipient_has_not_accepted',
    );
  });

  it('blocks additional messages while the request is pending', () => {
    expect(getMessageSendDenial({ ...pendingRequest, hasExistingMessage: true })).toBe(
      'initial_request_already_sent',
    );
  });

  it('blocks rejected requests', () => {
    expect(getMessageSendDenial({ ...pendingRequest, requestStatus: 'rejected' })).toBe(
      'rejected_request',
    );
  });

  it('allows normal messages after acceptance', () => {
    expect(getMessageSendDenial({
      ...pendingRequest,
      requestStatus: 'accepted',
      hasExistingMessage: true,
    })).toBeNull();
  });
});