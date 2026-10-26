import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../../core/constants/api_constants.dart';
import 'storage_service.dart';
import 'upload_queue.dart';

class ApiService {
  static final ApiService _instance = ApiService._();
  factory ApiService() => _instance;
  ApiService._() : _useStoredToken = true;

  /// Account-owned requests never pick up another account's token mid-flight.
  /// A null token here means unauthenticated, not "fall back to storage".
  ApiService.withToken(String? token) : _token = token, _useStoredToken = false;

  /// Fired when the server rejects the current token because the device was
  /// terminated elsewhere (Item 4). The auth provider signs the user out.
  static void Function(String code)? onUnauthorized;

  final bool _useStoredToken;
  String? _token;

  /// Conditional-GET cache: the server answers unchanged polls with a 304
  /// and an ETag, so a `{etag, body}` pair per URL lets the 3-second polling
  /// reuse the last body instead of re-downloading the whole history. The
  /// server still re-renders and revalidates every request — correctness
  /// never depends on this cache; it only saves bandwidth on slow links.
  static final Map<String, ({String etag, Map<String, dynamic> body})>
      _etagCache = {};

  void setToken(String? token) {
    _token = token;
  }

  Map<String, String> get _headers {
    final h = {'Accept': 'application/json'};
    final token =
        _token ?? (_useStoredToken ? StorageService.getToken() : null);
    if (token != null) {
      h['Authorization'] = 'Bearer $token';
    }
    return h;
  }

  Map<String, String> get _jsonHeaders {
    final h = _headers;
    h['Content-Type'] = 'application/json';
    return h;
  }

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(
        statusCode: 0,
        message: 'اتصال به سرور برقرار نشد. اینترنت را بررسی کنید.',
        code: 'timeout',
      );
    } on SocketException {
      throw ApiException(
        statusCode: 0,
        message: 'اتصال به سرور برقرار نشد. اینترنت یا فیلترشکن را بررسی کنید.',
        code: 'network',
      );
    } on http.ClientException catch (e) {
      throw ApiException(
        statusCode: 0,
        message: 'خطای اتصال: ${e.message}',
        code: 'network',
      );
    }
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
  }) =>
      _guard(() async {
        final res = await http
            .post(
              Uri.parse('${ApiConstants.baseUrl}$path'),
              headers: {..._jsonHeaders, ...?headers},
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 30));
        return _handle(res, path: path);
      });

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
  }) =>
      _guard(() async {
        final uri = Uri.parse(
          '${ApiConstants.baseUrl}$path',
        ).replace(queryParameters: query);
        final requestHeaders = {..._headers, ...?headers};
        final cacheKey =
            '$uri|${requestHeaders['Authorization'] ?? ''}|'
            '${requestHeaders['X-Archive-Token'] ?? ''}';
        final cached = _etagCache[cacheKey];
        if (cached != null) {
          requestHeaders['If-None-Match'] = cached.etag;
        }
        final res = await http
            .get(uri, headers: requestHeaders)
            .timeout(const Duration(seconds: 30));
        if (res.statusCode == 304 && cached != null) {
          return cached.body;
        }
        final body = _handle(res, path: path);
        final etag = res.headers['etag'];
        if (etag != null && res.statusCode == 200) {
          _etagCache[cacheKey] = (etag: etag, body: body);
          if (_etagCache.length > 64) {
            _etagCache.remove(_etagCache.keys.first);
          }
        }
        return body;
      });

  /// Ephemeral media is kept in memory and never passed to an image disk cache.
  Future<Uint8List> getBytes(String path) => _guard(() async {
        final response = await http
            .get(
              Uri.parse('${ApiConstants.baseUrl}$path'),
              headers: {..._headers, 'Cache-Control': 'no-store'},
            )
            .timeout(const Duration(seconds: 45));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw _errorFor(response, fallback: 'بارگذاری عکس ناموفق بود');
        }
        return response.bodyBytes;
      });

  Future<Map<String, dynamic>> put(
    String path,
    Map<String, dynamic> body,
  ) =>
      _guard(() async {
        final res = await http
            .put(
              Uri.parse('${ApiConstants.baseUrl}$path'),
              headers: _jsonHeaders,
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 30));
        return _handle(res, path: path);
      });

  Future<Map<String, dynamic>> uploadFile(
    String path,
    File file, {
    String fieldName = 'file',
    Map<String, String>? fields,
    void Function(double progress)? onProgress,
    UploadCancellationToken? cancellationToken,
  }) =>
      _guard(() async {
        cancellationToken?.throwIfCancelled();
        final uri = Uri.parse('${ApiConstants.baseUrl}$path');
        final request = _ProgressMultipartRequest(
          'POST',
          uri,
          onProgress: onProgress,
          abortTrigger: cancellationToken?.whenCancelled,
        );
        request.headers.addAll(_headers);
        if (fields != null) request.fields.addAll(fields);

        final ext = file.path.split('.').last.toLowerCase();
        String mime = 'application/octet-stream';
        if (['jpg', 'jpeg'].contains(ext)) {
          mime = 'image/jpeg';
        } else if (ext == 'png') {
          mime = 'image/png';
        } else if (ext == 'gif') {
          mime = 'image/gif';
        } else if (ext == 'webp') {
          mime = 'image/webp';
        } else if (ext == 'mp4') {
          mime = 'video/mp4';
        } else if (ext == 'mp3') {
          mime = 'audio/mpeg';
        } else if (ext == 'm4a') {
          mime = 'audio/mp4';
        }

        request.files.add(
          await http.MultipartFile.fromPath(
            fieldName,
            file.path,
            contentType: MediaType.parse(mime),
          ),
        );
        cancellationToken?.throwIfCancelled();

        try {
          final streamed = await request.send();
          final res = await http.Response.fromStream(streamed);
          return _handle(res, path: path);
        } catch (_) {
          if (cancellationToken?.isCancelled == true) {
            throw const UploadCancelledException();
          }
          rethrow;
        }
      });

  Map<String, dynamic> _handle(http.Response res, {String? path}) {
    final body = _decodeBody(res);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return body;
    }
    throw _errorFor(res, body: body, path: path);
  }

  /// Never throws: HTML proxy errors, empty bodies and non-object JSON all
  /// become a plain map so the UI never shows a red `<!DOCTYPE ...>` crash.
  Map<String, dynamic> _decodeBody(http.Response res) {
    if (res.body.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return <String, dynamic>{'data': decoded};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  ApiException _errorFor(
    http.Response res, {
    Map<String, dynamic>? body,
    String? path,
    String? fallback,
  }) {
    body ??= _decodeBody(res);
    final code = body['code'] as String?;
    var message = body['error'] as String?;
    message ??= fallback;
    if (message == null || message.isEmpty || _looksLikeHtml(message)) {
      message = _friendlyMessage(res.statusCode);
    }
    // A reverse proxy / Passenger crash returns HTML with no JSON body.
    if ((message.isEmpty || _looksLikeHtml(res.body)) &&
        _looksLikeHtml(res.body)) {
      message = _friendlyMessage(res.statusCode);
    }
    if (res.statusCode == 401 &&
        (code == 'device_terminated' || code == 'session_ended')) {
      // Fire async: throwing must not depend on the logout completing.
      final cb = onUnauthorized;
      if (cb != null) scheduleMicrotask(() => cb(code!));
    }
    return ApiException(
      statusCode: res.statusCode,
      message: message,
      code: code,
      details: body,
    );
  }

  bool _looksLikeHtml(String text) {
    final t = text.trimLeft().toLowerCase();
    return t.startsWith('<!doctype') ||
        t.startsWith('<html') ||
        t.startsWith('<head') ||
        t.startsWith('<body');
  }

  String _friendlyMessage(int status) {
    if (status == 0) return 'اتصال به سرور برقرار نشد.';
    if (status == 400) return 'درخواست نامعتبر است.';
    if (status == 401) return 'نشست شما منقضی شده است. لطفاً دوباره وارد شوید.';
    if (status == 403) return 'دسترسی ندارید.';
    if (status == 404) return 'یافت نشد.';
    if (status == 409) return 'این مورد قبلاً ثبت شده است.';
    if (status == 410) return 'این مورد دیگر در دسترس نیست.';
    if (status == 422) return 'نشست نامعتبر است. لطفاً دوباره وارد شوید.';
    if (status == 429) return 'تعداد درخواست‌ها زیاد است. کمی بعد تلاش کنید.';
    if (status >= 500) {
      return 'خطای موقت سرور. لطفاً چند لحظه بعد دوباره تلاش کنید.';
    }
    return 'خطای ناشناخته ($status)';
  }
}

// AbortableMultipartRequest is final, so mix in the public Abortable contract
// on our progress-reporting MultipartRequest instead.
class _ProgressMultipartRequest extends http.MultipartRequest
    with http.Abortable {
  final void Function(double progress)? onProgress;
  @override
  final Future<void>? abortTrigger;

  _ProgressMultipartRequest(
    super.method,
    super.url, {
    this.onProgress,
    this.abortTrigger,
  });

  @override
  http.ByteStream finalize() {
    final byteStream = super.finalize();
    final total = contentLength;
    int sent = 0;
    final stream = byteStream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (data, sink) {
          sent += data.length;
          if (total > 0 && onProgress != null) {
            onProgress!(sent / total);
          }
          sink.add(data);
        },
      ),
    );
    return http.ByteStream(stream);
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String message;
  final String? code;

  /// The full decoded JSON error body, so callers can read extra fields such
  /// as `retry_after_seconds` on a 429 without re-parsing the response.
  final Map<String, dynamic> details;

  ApiException({
    required this.statusCode,
    required this.message,
    this.code,
    Map<String, dynamic>? details,
  }) : details = details ?? const {};

  /// True when the current device was signed out remotely.
  bool get isDeviceTerminated =>
      statusCode == 401 &&
      (code == 'device_terminated' || code == 'session_ended');

  @override
  String toString() => message;
}
