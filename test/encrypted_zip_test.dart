import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingzhang/services/encrypted_zip.dart';

void main() {
  // fixture 由 InfoZIP `zip -P test123` 生成（标准传统 ZipCrypto），
  // 已用 python zipfile 官方解密交叉验证过。
  Uint8List fixture() => Uint8List.fromList(
      File('test/fixtures/cmb_encrypted_test.zip').readAsBytesSync());

  test('正确密码可解密出内容', () {
    final out = decryptZipWithCentral(fixture(), 'test123');
    expect(out.length, 1, reason: '应解出一个条目');
    final text = utf8.decode(out.values.first);
    expect(text, contains('2026-07-08'));
    expect(text, contains('五华区鑫员点心铺'));
  });

  test('错误密码抛异常（不解出乱码）', () {
    expect(() => decryptZipWithCentral(fixture(), 'wrongpass'),
        throwsException);
  });
}
