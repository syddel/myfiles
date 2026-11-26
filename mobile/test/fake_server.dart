import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:myfiles_mobile/api/api_client.dart';

/// A tiny in-memory MyFiles server for widget tests.
class FakeServer implements HttpClientAdapter {
  FakeServer() {
    _add(id: 1, parent: null, name: '', dir: true);
    _add(id: 2, parent: 1, name: 'Photos', dir: true);
    _add(id: 3, parent: 1, name: 'notes.txt', dir: false, size: 12, kind: 'text');
    _add(id: 4, parent: 2, name: 'beach.jpg', dir: false, size: 2048, kind: 'image');
    _add(id: 5, parent: 1, name: 'report.pdf', dir: false, size: 300000, kind: 'pdf');
  }

  final nodes = <int, Map<String, dynamic>>{};
  final shares = <int, Map<String, dynamic>>{};
  final requests = <String>[];
  int _nextId = 100;
  bool signedIn = false;

  /// Pretend the phone has no network (every request fails to connect).
  bool offline = false;
  String folderColor = 'amber';
  String theme = 'system';

  void _add({
    required int id,
    required int? parent,
    required String name,
    required bool dir,
    int size = 0,
    String? kind,
  }) {
    nodes[id] = {
      'id': id,
      'parent_id': parent,
      'name': name,
      'is_dir': dir,
      'size': size,
      'mime_type': null,
      'kind': kind ?? (dir ? 'folder' : 'other'),
      'updated_at': '2026-11-01T10:00:00',
    };
  }

  Map<String, dynamic> get _user => {
    'id': 7,
    'username': 'alice',
    'root_id': 1,
    'folder_color': folderColor,
    'theme': theme,
    'is_admin': false,
  };

  Map<String, dynamic> _out(Map<String, dynamic> n) => {...n, 'share': shares[n['id']]?['mode']};

  List<Map<String, dynamic>> _crumbs(int id) {
    final out = <Map<String, dynamic>>[];
    int? cur = id;
    while (cur != null) {
      out.insert(0, {'id': cur, 'name': nodes[cur]!['name']});
      cur = nodes[cur]!['parent_id'] as int?;
    }
    return out;
  }

  void _deleteTree(int id) {
    for (final child in nodes.values.where((n) => n['parent_id'] == id).toList()) {
      _deleteTree(child['id'] as int);
    }
    nodes.remove(id);
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (offline) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: 'Network is unreachable',
      );
    }
    final path = options.uri.path.replaceFirst(RegExp(r'^.*/api/'), '');
    final method = options.method;
    requests.add('$method $path');
    if (options.headers['X-Requested-With'] != 'myfiles') return _json({'detail': 'missing header'}, 403);
    final body = options.data is Map ? options.data as Map : const {};
    final authed = signedIn && '${options.headers['Cookie']}'.contains('$sessionCookie=tok');

    if (path == 'config') {
      return _json({
        'app_name': 'Test Files',
        'registration_open': true,
        'invite_required': false,
        'max_upload_bytes': 0,
      });
    }
    if (path == 'auth/login') {
      if (body['password'] != 'secret') return _json({'detail': 'Wrong username or password'}, 401);
      signedIn = true;
      return _json(_user, 200, {
        'set-cookie': ['$sessionCookie=tok; HttpOnly; Path=/'],
      });
    }
    if (!authed) return _json({'detail': 'Not signed in'}, 401);
    if (path == 'auth/logout') {
      signedIn = false;
      return _json({'ok': true});
    }
    if (path == 'auth/me') return _json(_user);
    if (path == 'auth/preferences') {
      folderColor = body['folder_color'] as String? ?? folderColor;
      theme = body['theme'] as String? ?? theme;
      return _json(_user);
    }
    if (path == 'stats') {
      return _json({
        'used_bytes': 302060,
        'file_count': 3,
        'quota_bytes': 15 * 1024 * 1024 * 1024,
        'disk_free': 1 << 40,
      });
    }
    if (path == 'folders' && method == 'GET') {
      return _json([
        for (final n in nodes.values.where((n) => n['is_dir'] == true))
          {'id': n['id'], 'parent_id': n['parent_id'], 'name': n['name']},
      ]);
    }
    if (path == 'folders' && method == 'POST') {
      final id = _nextId++;
      _add(id: id, parent: body['parent_id'] as int, name: body['name'] as String, dir: true);
      return _json(_out(nodes[id]!), 201);
    }
    final folder = RegExp(r'^folders/(\d+)$').firstMatch(path);
    if (folder != null) {
      final id = int.parse(folder[1]!);
      if (nodes[id] == null) return _json({'detail': 'Not found'}, 404);
      return _json({
        'folder': _out(nodes[id]!),
        'breadcrumb': _crumbs(id),
        'items': [for (final n in nodes.values.where((n) => n['parent_id'] == id)) _out(n)],
      });
    }
    if (path == 'search') {
      final q = (options.uri.queryParameters['q'] ?? '').toLowerCase();
      return _json([
        for (final n in nodes.values.where(
          (n) => n['parent_id'] != null && (n['name'] as String).toLowerCase().contains(q),
        ))
          {..._out(n), 'path': n['parent_id'] == 1 ? '/' : '/${nodes[n['parent_id']]!['name']}'},
      ]);
    }
    final node = RegExp(r'^nodes/(\d+)$').firstMatch(path);
    if (node != null && method == 'PATCH') {
      final n = nodes[int.parse(node[1]!)]!;
      n['name'] = body['name'];
      return _json(_out(n));
    }
    if (path == 'nodes/move') {
      for (final id in body['ids'] as List) {
        nodes[id]!['parent_id'] = body['target_id'];
      }
      return _json({'ok': true});
    }
    if (path == 'nodes/delete') {
      for (final id in body['ids'] as List) {
        _deleteTree(id as int);
      }
      return _json({'ok': true});
    }
    if (path == 'shares') return _json([for (final s in shares.values) s]);
    final share = RegExp(r'^shares/(\d+)(/password)?$').firstMatch(path);
    if (share != null) {
      final id = int.parse(share[1]!);
      if (share[2] != null) {
        shares[id]!['has_password'] = body['password'] != null;
        return _json(shares[id]);
      }
      switch (method) {
        case 'GET':
          return _json(shares[id]);
        case 'DELETE':
          shares.remove(id);
          return _json({'ok': true});
        default:
          final n = nodes[id]!;
          shares[id] = {
            'node_id': id,
            'parent_id': n['parent_id'],
            'is_dir': n['is_dir'],
            'kind': n['kind'],
            'path': '/',
            'name': n['name'],
            'mode': body['mode'],
            'has_password': shares[id]?['has_password'] ?? false,
            'token': 's/abc$id',
            'url': null,
          };
          return _json(shares[id]);
      }
    }
    final content = RegExp(r'^files/(\d+)/content$').firstMatch(path);
    if (content != null) {
      return ResponseBody.fromString(
        'hello world\n',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/plain'],
        },
      );
    }
    return _json({'detail': 'Not found: $method $path'}, 404);
  }

  ResponseBody _json(Object? data, [int status = 200, Map<String, List<String>> extra = const {}]) =>
      ResponseBody.fromString(
        jsonEncode(data),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          ...extra,
        },
      );

  @override
  void close({bool force = false}) {}

  ApiClient client(Uri server, String? session) =>
      ApiClient(server, session: session, dio: Dio()..httpClientAdapter = this);
}
