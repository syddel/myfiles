// Data returned by the MyFiles server API (see myfiles/api.py and myfiles/shares.py).

class ServerConfig {
  ServerConfig({
    required this.appName,
    required this.registrationOpen,
    required this.inviteRequired,
    required this.maxUploadBytes,
  });

  final String appName;
  final bool registrationOpen;
  final bool inviteRequired;
  final int maxUploadBytes; // 0 = no limit

  factory ServerConfig.fromJson(Map<String, dynamic> j) => ServerConfig(
    appName: j['app_name'] as String? ?? 'MyFiles',
    registrationOpen: j['registration_open'] as bool? ?? false,
    inviteRequired: j['invite_required'] as bool? ?? false,
    maxUploadBytes: (j['max_upload_bytes'] as num?)?.toInt() ?? 0,
  );
}

class User {
  User({
    required this.id,
    required this.username,
    required this.rootId,
    required this.folderColor,
    required this.theme,
    required this.isAdmin,
  });

  final int id;
  final String username;
  final int rootId;
  final String folderColor;
  final String theme; // system | light | dark
  final bool isAdmin;

  factory User.fromJson(Map<String, dynamic> j) => User(
    id: j['id'] as int,
    username: j['username'] as String,
    rootId: j['root_id'] as int,
    folderColor: j['folder_color'] as String? ?? 'amber',
    theme: j['theme'] as String? ?? 'system',
    isAdmin: j['is_admin'] as bool? ?? false,
  );
}

/// A file or folder.
class Node {
  Node({
    required this.id,
    required this.parentId,
    required this.name,
    required this.isDir,
    required this.size,
    required this.mimeType,
    required this.kind,
    required this.updatedAt,
    this.share,
    this.path,
  });

  final int id;
  final int? parentId;
  final String name;
  final bool isDir;
  final int size;
  final String? mimeType;
  final String kind; // folder | pdf | image | audio | video | text | archive | other
  final DateTime updatedAt;
  final String? share; // "read" / "readwrite" when shared by link
  final String? path; // search results only: the folder it's in, e.g. "/Photos"

  bool get previewable => const {'image', 'video', 'audio', 'text'}.contains(kind);

  factory Node.fromJson(Map<String, dynamic> j) => Node(
    id: j['id'] as int,
    parentId: j['parent_id'] as int?,
    name: j['name'] as String,
    isDir: j['is_dir'] as bool,
    size: (j['size'] as num?)?.toInt() ?? 0,
    mimeType: j['mime_type'] as String?,
    kind: j['kind'] as String? ?? 'other',
    updatedAt: DateTime.parse(j['updated_at'] as String).toLocal(),
    share: j['share'] as String?,
    path: j['path'] as String?,
  );
}

class Crumb {
  Crumb(this.id, this.name);
  final int id;
  final String name;
}

class FolderListing {
  FolderListing({required this.folder, required this.breadcrumb, required this.items});

  final Node folder;
  final List<Crumb> breadcrumb;
  final List<Node> items;

  factory FolderListing.fromJson(Map<String, dynamic> j) => FolderListing(
    folder: Node.fromJson(j['folder'] as Map<String, dynamic>),
    breadcrumb: [for (final c in j['breadcrumb'] as List) Crumb(c['id'] as int, c['name'] as String)],
    items: [for (final n in j['items'] as List) Node.fromJson(n as Map<String, dynamic>)],
  );
}

class FolderRef {
  FolderRef({required this.id, required this.parentId, required this.name});
  final int id;
  final int? parentId;
  final String name;

  factory FolderRef.fromJson(Map<String, dynamic> j) =>
      FolderRef(id: j['id'] as int, parentId: j['parent_id'] as int?, name: j['name'] as String);
}

class Stats {
  Stats({required this.usedBytes, required this.fileCount, required this.quotaBytes, required this.diskFree});

  final int usedBytes;
  final int fileCount;
  final int? quotaBytes; // null = unlimited
  final int diskFree;

  factory Stats.fromJson(Map<String, dynamic> j) => Stats(
    usedBytes: (j['used_bytes'] as num).toInt(),
    fileCount: (j['file_count'] as num).toInt(),
    quotaBytes: (j['quota_bytes'] as num?)?.toInt(),
    diskFree: (j['disk_free'] as num?)?.toInt() ?? 0,
  );
}

/// A share link for a folder or file.
class ShareInfo {
  ShareInfo({
    required this.nodeId,
    required this.parentId,
    required this.isDir,
    required this.kind,
    required this.path,
    required this.name,
    required this.mode,
    required this.hasPassword,
    required this.token,
    required this.url,
  });

  final int nodeId;
  final int? parentId;
  final bool isDir;
  final String kind;
  final String path;
  final String name;
  final String mode; // read | readwrite
  final bool hasPassword;
  final String token;
  final String? url; // null when the server has no BASE_URL

  factory ShareInfo.fromJson(Map<String, dynamic> j) => ShareInfo(
    nodeId: j['node_id'] as int,
    parentId: j['parent_id'] as int?,
    isDir: j['is_dir'] as bool,
    kind: j['kind'] as String? ?? 'other',
    path: j['path'] as String? ?? '',
    name: j['name'] as String,
    mode: j['mode'] as String,
    hasPassword: j['has_password'] as bool? ?? false,
    token: j['token'] as String,
    url: j['url'] as String?,
  );
}
