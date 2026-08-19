import 'package:wanling_core/services/local_message_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqlite3/common.dart';

class _MockCommonDatabase extends Mock implements CommonDatabase {}

ResultSet _cipherVersionResult(Object? value) {
  return ResultSet(['cipher_version'], null, [
    [value]
  ]);
}

const _emptyRows = <List<Object?>>[];
ResultSet _emptyCipherVersionResult() {
  return ResultSet(['cipher_version'], null, _emptyRows);
}

void main() {
  group('LocalMessageDatabase.validateSqlCipher', () {
    late _MockCommonDatabase db;

    setUp(() {
      db = _MockCommonDatabase();
    });

    test('空结果集(模拟普通 SQLite)抛 StateError', () {
      when(() => db.select('PRAGMA cipher_version;'))
          .thenReturn(_emptyCipherVersionResult());

      expect(
        () => LocalMessageDatabase.validateSqlCipher(db),
        throwsA(isA<StateError>()),
      );
    });

    test('含 cipher_version 字符串行(模拟 SQLCipher 4.x)不抛', () {
      when(() => db.select('PRAGMA cipher_version;'))
          .thenReturn(_cipherVersionResult('4.5.5 community'));

      expect(
        () => LocalMessageDatabase.validateSqlCipher(db),
        returnsNormally,
      );
    });

    test('含空字符串行(边界)视为无 cipher 抛 StateError', () {
      when(() => db.select('PRAGMA cipher_version;'))
          .thenReturn(_cipherVersionResult(''));

      expect(
        () => LocalMessageDatabase.validateSqlCipher(db),
        throwsA(isA<StateError>()),
      );
    });
  });
}
