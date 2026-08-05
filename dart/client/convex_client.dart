/// A small educational Dart client for Convex's documented HTTP API and the
/// explicitly pinned experimental sync profile. It is not an official SDK.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'live_client.dart';

const _defaultClientVersion = 'dart-0.1.0';
const _maximumResponseBytes = 2 * 1024 * 1024;

/// A successful Convex function result. JSON stays decoded so applications can
/// map it into their own idiomatic Dart values without losing log lines.
class ConvexResult {
  const ConvexResult(this.value, this.logs);

  final Object? value;
  final List<String> logs;
}

/// Base class for failures whose kind matters to an adapter or application.
sealed class ConvexError implements Exception {
  const ConvexError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Convex ran the function and returned a structured application failure.
final class FunctionError extends ConvexError {
  const FunctionError({
    required this.operation,
    required String message,
    this.data,
    this.logs = const [],
  }) : super(message);

  final String operation;
  final Object? data;
  final List<String> logs;
}

/// The peer returned a response outside the pinned protocol contract.
final class ProtocolError extends ConvexError {
  const ProtocolError(super.message);
}

/// A network, TLS, timeout, or HTTP decoding failure.
final class TransportError extends ConvexError {
  const TransportError(this.operation, String detail)
    : super('$operation: $detail');

  final String operation;
}

/// A method was used after [ConvexClient.close].
final class ClientClosedError extends ConvexError {
  const ClientClosedError() : super('Convex client is closed');
}

/// Native Dart implementation of the documented Convex HTTP function API.
class ConvexClient {
  ConvexClient(
    String deploymentUrl, {
    HttpClient? httpClient,
    String clientVersion = _defaultClientVersion,
  }) : _baseUri = _parseDeploymentUrl(deploymentUrl),
       _httpClient = httpClient ?? HttpClient(),
       _clientVersion = clientVersion;

  final Uri _baseUri;
  final HttpClient _httpClient;
  final String _clientVersion;
  String _authToken = '';
  bool _closed = false;
  LiveClient? _live;

  /// Changes the bearer token sent to later HTTP requests. An empty token
  /// deliberately clears authentication, which the adapter tests exercise.
  void setAuth(String token) {
    _assertOpen();
    _authToken = token;
  }

  Future<ConvexResult> query(String path, Map<String, Object?> args) =>
      _call('query', path, args);

  Future<ConvexResult> mutation(String path, Map<String, Object?> args) =>
      _call('mutation', path, args);

  Future<ConvexResult> action(String path, Map<String, Object?> args) =>
      _call('action', path, args);

  /// Starts a reactive query using the pinned sync profile. One [LiveClient]
  /// owns every socket and query-set mutation for this HTTP client.
  Future<LiveSubscription> subscribe(String path, Map<String, Object?> args) {
    _assertOpen();
    _live ??= LiveClient(_baseUri, _clientVersion);
    return _live!.subscribe(path, args);
  }

  /// Test-only adapter hook. Normal educational API users cannot accidentally
  /// call it because it is only imported by the conformance executable.
  Future<void> debugDisconnectForAdapter() {
    _assertOpen();
    final live = _live;
    if (live == null) {
      throw const ProtocolError('Live WebSocket has not been started');
    }
    return live.debugDisconnect();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _live?.close();
    _httpClient.close(force: true);
  }

  Future<ConvexResult> _call(
    String operation,
    String path,
    Map<String, Object?> args,
  ) async {
    _assertOpen();
    if (path.isEmpty)
      throw const ProtocolError('Convex function path is required');
    final uri = _baseUri.replace(path: '${_baseUri.path}/api/$operation');
    try {
      final request = await _httpClient
          .postUrl(uri)
          .timeout(const Duration(seconds: 30));
      request.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set('Convex-Client', _clientVersion);
      if (_authToken.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $_authToken',
        );
      }
      // HttpClientRequest.write defaults to Latin-1. Send explicit UTF-8 bytes
      // so ordinary Convex JSON values can include every Unicode character.
      request.add(
        utf8.encode(jsonEncode({'path': path, 'args': args, 'format': 'json'})),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final bytes = await _readLimited(response);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const ProtocolError('HTTP response was not a Convex object');
      }
      final logs = _stringList(decoded['logLines']);
      switch (decoded['status']) {
        case 'success':
          if (!decoded.containsKey('value')) {
            throw const ProtocolError('success response omitted value');
          }
          return ConvexResult(decoded['value'], logs);
        case 'error':
          throw FunctionError(
            operation: operation,
            message:
                decoded['errorMessage']?.toString() ?? 'Convex function failed',
            data: decoded['errorData'],
            logs: logs,
          );
        default:
          throw ProtocolError(
            'HTTP response has unknown status ${decoded['status']}',
          );
      }
    } on ConvexError {
      rethrow;
    } on TimeoutException catch (error) {
      throw TransportError(operation, error.toString());
    } on SocketException catch (error) {
      throw TransportError(operation, error.toString());
    } on HttpException catch (error) {
      throw TransportError(operation, error.toString());
    } on FormatException catch (error) {
      throw TransportError(operation, 'non-JSON HTTP response: $error');
    } catch (error) {
      throw TransportError(operation, error.toString());
    }
  }

  void _assertOpen() {
    if (_closed) throw const ClientClosedError();
  }
}

Uri _parseDeploymentUrl(String value) {
  final uri = Uri.parse(value);
  if ((uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'Convex deployment URL must be an HTTP(S) host without user information',
    );
  }
  return uri.replace(
    path: uri.path.replaceFirst(RegExp(r'/+$'), ''),
    query: null,
    fragment: null,
  );
}

Future<List<int>> _readLimited(HttpClientResponse response) async {
  final output = BytesBuilder(copy: false);
  await for (final chunk in response) {
    output.add(chunk);
    if (output.length > _maximumResponseBytes) {
      throw const TransportError(
        'HTTP response',
        'response exceeds 2097152 bytes',
      );
    }
  }
  return output.takeBytes();
}

List<String> _stringList(Object? value) =>
    value is List
        ? value.whereType<String>().toList(growable: false)
        : const [];
