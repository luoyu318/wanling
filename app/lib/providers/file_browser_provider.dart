import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/file_content.dart';
import 'package:wanling_core/models/file_entry.dart';
import '../services/api_service.dart';
import 'auth_provider.dart' show apiProvider;

typedef FileBrowserKey = ({String agentId, String convId});

class FileBrowserState {
  final String currentPath;
  final AsyncValue<List<FileEntry>> entries;
  final bool entriesTruncated;
  final AsyncValue<FileContent>? previewContent;
  final List<String> pathStack;

  const FileBrowserState({
    this.currentPath = '.',
    this.entries = const AsyncValue.loading(),
    this.entriesTruncated = false,
    this.previewContent,
    this.pathStack = const [],
  });

  FileBrowserState copyWith({
    String? currentPath,
    AsyncValue<List<FileEntry>>? entries,
    bool? entriesTruncated,
    AsyncValue<FileContent>? previewContent,
    List<String>? pathStack,
    bool clearPreview = false,
  }) =>
      FileBrowserState(
        currentPath: currentPath ?? this.currentPath,
        entries: entries ?? this.entries,
        entriesTruncated: entriesTruncated ?? this.entriesTruncated,
        previewContent: clearPreview ? null : (previewContent ?? this.previewContent),
        pathStack: pathStack ?? this.pathStack,
      );
}

class FileBrowserNotifier extends StateNotifier<FileBrowserState> {
  final ApiService _api;
  final String agentId;
  final String convId;

  FileBrowserNotifier(this._api, {required this.agentId, required this.convId})
      : super(const FileBrowserState()) {
    loadDirectory('.');
  }

  Future<void> loadDirectory(String path) async {
    state = state.copyWith(
      currentPath: path,
      entries: const AsyncValue.loading(),
      clearPreview: true,
    );
    try {
      final result = await _api.rpc(
        agentId,
        'file.list',
        {'wanling_conv_id': convId, 'path': path},
        timeoutMs: 5000,
      );
      final list = (result['entries'] as List?) ?? const [];
      state = state.copyWith(
        entries: AsyncValue.data(
          list.map((e) => FileEntry.fromJson(e as Map<String, dynamic>)).toList(),
        ),
        entriesTruncated: (result['truncated'] as bool?) ?? false,
      );
    } catch (e, st) {
      state = state.copyWith(entries: AsyncValue.error(e, st));
    }
  }

  Future<void> enterDirectory(String name) async {
    final next = state.currentPath == '.'
        ? name
        : '${state.currentPath}/$name';
    final stack = [...state.pathStack, state.currentPath];
    state = state.copyWith(pathStack: stack);
    await loadDirectory(next);
  }

  Future<void> goUp() async {
    if (state.pathStack.isEmpty) return;
    final stack = [...state.pathStack]..removeLast();
    final prev = stack.isEmpty ? '.' : state.pathStack.last;
    state = state.copyWith(pathStack: stack);
    await loadDirectory(prev);
  }

  Future<void> popTo(String path) async {
    if (path == state.currentPath) return;
    if (path == '.' || path.isEmpty) {
      state = state.copyWith(pathStack: const []);
      await loadDirectory('.');
      return;
    }
    final segments = path.split('/');
    final stack = <String>['.'];
    for (var i = 1; i < segments.length; i++) {
      stack.add(segments.sublist(0, i).join('/'));
    }
    state = state.copyWith(pathStack: stack);
    await loadDirectory(path);
  }

  Future<void> loadFileContent(FileEntry entry) async {
    state = state.copyWith(previewContent: const AsyncValue.loading());
    try {
      final path = state.currentPath == '.'
          ? entry.name
          : '${state.currentPath}/${entry.name}';
      final result = await _api.rpc(
        agentId,
        'file.read',
        {'wanling_conv_id': convId, 'path': path},
        timeoutMs: 5000,
      );
      state = state.copyWith(
        previewContent: AsyncValue.data(FileContent.fromJson(result)),
      );
    } catch (e, st) {
      state = state.copyWith(previewContent: AsyncValue.error(e, st));
    }
  }

  void clearFileContent() {
    state = state.copyWith(clearPreview: true);
  }
}

final fileBrowserProvider = StateNotifierProvider.autoDispose.family<
    FileBrowserNotifier, FileBrowserState, FileBrowserKey>(
  (ref, key) => FileBrowserNotifier(
    ref.watch(apiProvider),
    agentId: key.agentId,
    convId: key.convId,
  ),
);
