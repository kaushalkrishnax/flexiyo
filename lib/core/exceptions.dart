/// Base class for all Flexiyo application exceptions.
class FlexiyoException implements Exception {
  const FlexiyoException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'FlexiyoException($statusCode): $message';
}

/// Thrown when an HTTP request fails (non-2xx response).
class ApiException extends FlexiyoException {
  const ApiException(super.message, {super.statusCode});
}

/// Thrown when the user is not authenticated or JWT has expired.
class UnauthorizedException extends FlexiyoException {
  const UnauthorizedException([super.message = 'Unauthorized'])
      : super(statusCode: 401);
}

/// Thrown when a requested resource is not found.
class NotFoundException extends FlexiyoException {
  const NotFoundException([super.message = 'Not found'])
      : super(statusCode: 404);
}

/// Thrown when network connectivity is unavailable.
class NetworkException extends FlexiyoException {
  const NetworkException([super.message = 'Network error']) : super();
}

/// Thrown when Signal Protocol session or key operations fail.
class CryptoException extends FlexiyoException {
  const CryptoException(super.message);
}

/// Thrown when local database operations fail.
class StorageException extends FlexiyoException {
  const StorageException(super.message);
}

/// Thrown when message decryption fails (possibly tampered or out-of-order).
class DecryptionException extends CryptoException {
  const DecryptionException(super.message);
}
