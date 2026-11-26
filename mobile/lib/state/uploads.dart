import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';

enum UploadStatus { queued, uploading, done, failed, cancelled }

/// One file waiting to upload, uploading, or finished.
class UploadItem {
  UploadItem({required this.name, required this.size, required this.parentId, required this.open});

  final String name;
  final int size;
  final int parentId;

  /// Opens the file's bytes when the upload starts.
  final Stream<List<int>> Function() open;

  UploadStatus status = UploadStatus.queued;
  int sent = 0;
  String? error;
  CancelToken? _cancel;

  bool get active => status == UploadStatus.queued || status == UploadStatus.uploading;
  double get progress => size == 0 ? 1 : (sent / size).clamp(0, 1);
}

/// Uploads files a couple at a time, with progress and cancel.
class UploadQueue extends ChangeNotifier {
  UploadQueue(this.api, {this.parallel = 2});

  final ApiClient api;
  final int parallel;
  final items = <UploadItem>[];

  /// Called with the folder id after each successful upload, so open folders can refresh.
  final _finished = <void Function(int folderId)>{};
  void addFinishedListener(void Function(int folderId) fn) => _finished.add(fn);
  void removeFinishedListener(void Function(int folderId) fn) => _finished.remove(fn);

  int _running = 0;

  List<UploadItem> get active => items.where((i) => i.active).toList();
  int get pendingBytes => active.fold(0, (total, i) => total + i.size - i.sent);
  double get overallProgress {
    final counted = items.where((i) => i.status != UploadStatus.cancelled);
    final size = counted.fold<int>(0, (t, i) => t + i.size);
    final sent = counted.fold<int>(0, (t, i) => t + (i.status == UploadStatus.failed ? i.size : i.sent));
    return size == 0 ? 1 : sent / size;
  }

  void add(List<UploadItem> newItems) {
    items.addAll(newItems);
    notifyListeners();
    _pump();
  }

  void _pump() {
    while (_running < parallel) {
      final next = items.where((i) => i.status == UploadStatus.queued).firstOrNull;
      if (next == null) return;
      _start(next);
    }
  }

  Future<void> _start(UploadItem item) async {
    _running++;
    item.status = UploadStatus.uploading;
    item._cancel = CancelToken();
    notifyListeners();
    try {
      await api.upload(
        parentId: item.parentId,
        name: item.name,
        data: item.open(),
        length: item.size,
        cancelToken: item._cancel,
        onProgress: (sent, _) {
          item.sent = sent;
          notifyListeners();
        },
      );
      item.status = UploadStatus.done;
      item.sent = item.size;
      for (final fn in _finished.toList()) {
        fn(item.parentId);
      }
    } on ApiException catch (e) {
      if (item.status != UploadStatus.cancelled) {
        item.status = UploadStatus.failed;
        item.error = e.message;
      }
    } finally {
      item._cancel = null;
      _running--;
      notifyListeners();
      _pump();
    }
  }

  void cancel(UploadItem item) {
    if (!item.active) return;
    item.status = UploadStatus.cancelled;
    item._cancel?.cancel();
    notifyListeners();
  }

  void cancelAll() => active.forEach(cancel);

  /// Remove finished entries from the list.
  void clearFinished() {
    items.removeWhere((i) => !i.active);
    notifyListeners();
  }
}
