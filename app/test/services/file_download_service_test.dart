import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/file_download_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FileDownloadService', () {
    test('getLocalPath returns null when file not downloaded', () async {
      final svc = FileDownloadService(baseUrl: 'http://localhost', token: 't');
      final path = await svc.getLocalPath('nonexistent_file_id');
      expect(path, isNull);
    });

    test('DownloadProgress.fraction computes correctly', () {
      const p0 = DownloadProgress(fileId: 'a', received: 0, total: 100);
      expect(p0.fraction, 0);
      const p50 = DownloadProgress(fileId: 'a', received: 50, total: 100);
      expect(p50.fraction, 0.5);
      const pDone = DownloadProgress(fileId: 'a', received: 100, total: 100, done: true);
      expect(pDone.fraction, 1.0);
      expect(pDone.done, isTrue);
    });

    test('DownloadProgress with error', () {
      const p = DownloadProgress(
        fileId: 'a', received: 0, total: 100, error: 'network failed',
      );
      expect(p.error, 'network failed');
      expect(p.done, isFalse);
    });

    test('DownloadProgress zero total fraction is 0 (no div by zero)', () {
      const p = DownloadProgress(fileId: 'a', received: 0, total: 0);
      expect(p.fraction, 0);
    });
  });
}
