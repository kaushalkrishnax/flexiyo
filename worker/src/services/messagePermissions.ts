export type MessageEditDenial = 'not_sender' | 'unsent' | 'expired';
export type MessageSendDenial =
  | 'rejected_request'
  | 'recipient_has_not_accepted'
  | 'initial_request_already_sent';

export function getMessageSendDenial(input: {
  requestStatus: 'pending' | 'accepted' | 'rejected';
  initiatedById: string | null;
  userId: string;
  hasExistingMessage: boolean;
}): MessageSendDenial | null {
  if (input.requestStatus === 'rejected') return 'rejected_request';
  if (input.requestStatus === 'pending') {
    if (input.initiatedById !== input.userId) {
      return 'recipient_has_not_accepted';
    }
    if (input.hasExistingMessage) return 'initial_request_already_sent';
  }
  return null;
}

export function getMessageEditDenial(input: {
  senderId: string;
  userId: string;
  isUnsent: boolean;
  createdAt: number;
  now: number;
}): MessageEditDenial | null {
  if (input.senderId !== input.userId) return 'not_sender';
  if (input.isUnsent) return 'unsent';
  if (input.createdAt > input.now || input.now - input.createdAt >= 15 * 60) {
    return 'expired';
  }
  return null;
}