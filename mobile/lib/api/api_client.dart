import 'dart:convert';

import 'package:dio/dio.dart';

import 'models.dart';

/// An error from the server, with its message (e.g. "Wrong username or password").
class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status; // HTTP status; 0 = couldn't reach the server
  final String message;

  @override
  String toString() => message;
}

const sessionCookie = 'myfiles_session';

/// "files.example.com" -> "https://files.example.com/", keeping any sub-path
/// ("https://example.com/files" -> "https://example.com/files/").
Uri normalizeServerUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) throw const FormatException('Enter the address of your server');
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
    throw const FormatException('That doesn\'t look like a web address');
  }
  // Drop a trailing "#/…" or "?…" pasted from the browser, and ensure a trailing slash.
  var path = uri.path;
  if (!path.endsWith('/')) path = '$path/';
  // (Uri.replace keeps the query and fragment when given null, so rebuild it.)
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: path);
}

/// The session token from a login response's Set-Cookie header(s), if any.
String? sessionFromSetCookie(List<String>? headers) {
  for (final header in headers ?? const <String>[]) {
    for (final part in header.split(RegExp(r',(?=\s*\w+=)'))) {
      final cookie = part.trim();
      if (cookie.startsWith('$sessionCookie=')) {
        final value = cookie.substring(sessionCookie.length + 1).split(';').first;
        return value.isEmpty || value == '""' ? null : value;
      }
    }
  }
  return null;
}

/// Client for the MyFiles server API (/api/…).
class ApiClient {
  ApiClient(this.server, {this.session, Dio? dio, this.onUnauthorized}) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = server.resolve('api/').toString()
      ..connectTimeout = const Duration(seconds: 15)
      ..headers['X-Requested-With'] = 'myfiles';
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final token = session;
          if (token != null) options.headers['Cookie'] = '$sessionCookie=$token';
          handler.next(options);
        },
      ),
    );
  }

  final Uri server;
  final Dio _dio;

  /// The signed-in session, sent as the server's session cookie.
  String? session;

  /// Called when the server says the session is no longer valid.
  void Function()? onUnauthorized;

  /// Headers for loading file content directly (images, video, audio).
  Map<String, String> get mediaHeaders => {
    'X-Requested-With': 'myfiles',
    if (session != null) 'Cookie': '$sessionCookie=$session',
  };

  Future<T> _call<T>(
    Future<Response<dynamic>> Function() request,
    T Function(dynamic data) parse, {
    bool authCall = false,
  }) async {
    try {
      final response = await request();
      return parse(response.data);
    } on DioException catch (e) {
      throw _error(e, authCall: authCall);
    }
  }

  ApiException _error(DioException e, {bool authCall = false}) {
    final response = e.response;
    if (response == null) {
      if (e.type == DioExceptionType.cancel) return ApiException(0, 'Cancelled');
      return ApiException(0, 'Can\'t reach the server. Check the address and your connection.');
    }
    if (response.statusCode == 401 && !authCall) onUnauthorized?.call();
    var message = 'Something went wrong (${response.statusCode})';
    final data = response.data;
    Object? detail;
    if (data is Map) {
      detail = data['detail'];
    } else if (data is String && data.startsWith('{')) {
      try {
        detail = (jsonDecode(data) as Map)['detail'];
      } catch (_) {}
    } else if (data is List<int>) {
      try {
        detail = (jsonDecode(utf8.decode(data)) as Map)['detail'];
      } catch (_) {}
    }
    if (detail is String) message = detail;
    if (detail is List && detail.isNotEmpty && detail.first is Map) {
      message = (detail.first as Map)['msg']?.toString() ?? message;
    }
    if (detail == 'password_required') message = 'This link needs a password';
    return ApiException(response.statusCode ?? 0, message);
  }

  // ------------------------------------------------------------ account

  Future<ServerConfig> config() =>
      _call(() => _dio.get('config'), (d) => ServerConfig.fromJson(d as Map<String, dynamic>));

  Future<User> login(String username, String password) =>
      _signIn('auth/login', {'username': username, 'password': password});

  Future<User> register(String username, String password, String inviteCode) =>
      _signIn('auth/register', {'username': username, 'password': password, 'invite_code': inviteCode});

  Future<User> _signIn(String path, Map<String, dynamic> body) async {
    try {
      final response = await _dio.post(path, data: body);
      final token = sessionFromSetCookie(response.headers['set-cookie']);
      if (token == null) throw ApiException(500, 'The server didn\'t start a session');
      session = token;
      return User.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _error(e, authCall: true);
    }
  }

  Future<void> logout() async {
    try {
      await _dio.post('auth/logout');
    } on DioException {
      // Signing out locally is what matters.
    }
    session = null;
  }

  Future<User> me() => _call(() => _dio.get('auth/me'), (d) => User.fromJson(d as Map<String, dynamic>));

  Future<void> changePassword(String current, String next) =>
      _call(() => _dio.post('auth/password', data: {'current_password': current, 'new_password': next}), (_) {});

  Future<User> setPreferences({String? folderColor, String? theme}) => _call(
    () => _dio.put('auth/preferences', data: {'folder_color': ?folderColor, 'theme': ?theme}),
    (d) => User.fromJson(d as Map<String, dynamic>),
  );

  Future<Stats> stats() => _call(() => _dio.get('stats'), (d) => Stats.fromJson(d as Map<String, dynamic>));

  // ------------------------------------------------------------ browsing

  Future<FolderListing> folder(int id) =>
      _call(() => _dio.get('folders/$id'), (d) => FolderListing.fromJson(d as Map<String, dynamic>));

  Future<List<FolderRef>> allFolders() => _call(
    () => _dio.get('folders'),
    (d) => [for (final f in d as List) FolderRef.fromJson(f as Map<String, dynamic>)],
  );

  Future<List<Node>> search(String query) => _call(
    () => _dio.get('search', queryParameters: {'q': query}),
    (d) => [for (final n in d as List) Node.fromJson(n as Map<String, dynamic>)],
  );

  // ------------------------------------------------------------ changes

  Future<Node> createFolder(int parentId, String name) => _call(
    () => _dio.post('folders', data: {'parent_id': parentId, 'name': name}),
    (d) => Node.fromJson(d as Map<String, dynamic>),
  );

  Future<Node> rename(int id, String name) =>
      _call(() => _dio.patch('nodes/$id', data: {'name': name}), (d) => Node.fromJson(d as Map<String, dynamic>));

  Future<void> move(List<int> ids, int targetId) =>
      _call(() => _dio.post('nodes/move', data: {'ids': ids, 'target_id': targetId}), (_) {});

  Future<void> delete(List<int> ids) => _call(() => _dio.post('nodes/delete', data: {'ids': ids}), (_) {});

  /// Upload one file, streamed from [data]. Returns the new file.
  Future<Node> upload({
    required int parentId,
    required String name,
    required Stream<List<int>> data,
    required int length,
    String relativeDir = '',
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) => _call(
    () => _dio.post(
      'upload',
      queryParameters: {'parent_id': parentId, 'name': name, 'relative_dir': relativeDir},
      data: data,
      options: Options(
        headers: {Headers.contentLengthHeader: length, Headers.contentTypeHeader: 'application/octet-stream'},
        sendTimeout: null,
      ),
      onSendProgress: onProgress,
      cancelToken: cancelToken,
    ),
    (d) => Node.fromJson(d as Map<String, dynamic>),
  );

  // ------------------------------------------------------------ file content

  /// Address of a file's content, for previews (with [mediaHeaders]).
  Uri contentUrl(int id, {bool download = false}) =>
      Uri.parse(_dio.options.baseUrl).resolve('files/$id/content${download ? '?download=1' : ''}');

  /// The start of a text file (at most [limit] bytes), for previews.
  Future<String> textStart(int id, {int limit = 1024 * 1024}) => _call(
    () => _dio.get<List<int>>(
      'files/$id/content',
      options: Options(responseType: ResponseType.bytes, headers: {'Range': 'bytes=0-${limit - 1}'}),
    ),
    (d) => utf8.decode(d as List<int>, allowMalformed: true),
  );

  /// Why a file can't be streamed: ask the server for its first byte and
  /// describe the answer ("The server answered 401 …", "Couldn't reach the server …").
  Future<String> diagnose(int id) async {
    try {
      final response = await _dio.get<List<int>>(
        'files/$id/content',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Range': 'bytes=0-0'},
          validateStatus: (_) => true,
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      final code = response.statusCode ?? 0;
      if (code == 200 || code == 206) {
        return 'The server is sending the file normally, so it was probably a brief network problem.';
      }
      final reason = response.statusMessage;
      return 'The server answered $code${reason == null || reason.isEmpty ? '' : ' $reason'}.';
    } on DioException catch (e) {
      final cause = e.error ?? e.message;
      return 'Couldn\'t reach the server (${e.type.name}${cause == null ? '' : ': $cause'}).';
    }
  }

  /// Download a file (or, for a folder or several items, a zip) to [savePath].
  Future<void> downloadTo(
    String savePath, {
    int? fileId,
    List<int>? zipIds,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) => _call(
    () => _dio.download(
      fileId != null ? 'files/$fileId/content' : 'zip',
      savePath,
      queryParameters: fileId != null ? {'download': 1} : {'ids': zipIds},
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
      options: Options(listFormat: ListFormat.multi),
    ),
    (_) {},
  );

  // ------------------------------------------------------------ sharing

  Future<List<ShareInfo>> shares() => _call(
    () => _dio.get('shares'),
    (d) => [for (final s in d as List) ShareInfo.fromJson(s as Map<String, dynamic>)],
  );

  Future<ShareInfo?> getShare(int nodeId) =>
      _call(() => _dio.get('shares/$nodeId'), (d) => d == null ? null : ShareInfo.fromJson(d as Map<String, dynamic>));

  Future<ShareInfo> setShare(int nodeId, String mode) => _call(
    () => _dio.put('shares/$nodeId', data: {'mode': mode}),
    (d) => ShareInfo.fromJson(d as Map<String, dynamic>),
  );

  /// Set, change or (with null) remove a share's password.
  Future<ShareInfo> setSharePassword(int nodeId, String? password) => _call(
    () => _dio.put('shares/$nodeId/password', data: {'password': password}),
    (d) => ShareInfo.fromJson(d as Map<String, dynamic>),
  );

  Future<void> stopSharing(int nodeId) => _call(() => _dio.delete('shares/$nodeId'), (_) {});

  /// The link to give people: the server's BASE_URL link, or built from the server address.
  String shareLink(ShareInfo share) => share.url ?? server.resolve(share.token).toString();
}
