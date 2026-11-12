import 'package:flexiyo/services/api_service.dart';

class ConversationKeyRepository {
  ConversationKeyRepository(this._api);

  final ApiService _api;

  Future<Map<String, dynamic>> getEpochs(String conversationId) =>
      _api.fetchConversationKeyEpochs(conversationId);

  Future<List<Map<String, dynamic>>> getDeviceKeys(String userId) =>
      _api.fetchConversationDeviceKeys(userId);

  Future<Map<String, dynamic>> getEnvelopes(
    String conversationId, {
    int? epoch,
  }) =>
      _api.fetchConversationKeyEnvelopes(conversationId, epoch: epoch);

  Future<void> publishEpoch({
    required String conversationId,
    required int epoch,
    required List<Map<String, dynamic>> envelopes,
  }) async {
    await _api.publishConversationKeyEpoch(
      conversationId: conversationId,
      epoch: epoch,
      envelopes: envelopes,
    );
  }

  Future<void> addEnvelopes({
    required String conversationId,
    required int epoch,
    required List<Map<String, dynamic>> envelopes,
  }) async {
    if (envelopes.isEmpty) return;
    await _api.addConversationKeyEnvelopes(
      conversationId: conversationId,
      epoch: epoch,
      envelopes: envelopes,
    );
  }
}
