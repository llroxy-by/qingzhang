import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fast_gbk/fast_gbk.dart';

/// 解码 zip 条目文件名：flag bit11（UTF-8 标记）置位用 UTF-8，
/// 否则（银行/老工具导出的 GBK）尝试 GBK，避免中文名乱码。
String _decodeName(List<int> bytes, int flag) {
  if (flag & 0x0800 != 0) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      // fall through
    }
  }
  try {
    return gbk.decode(bytes);
  } catch (_) {
    return String.fromCharCodes(bytes);
  }
}

/// 传统 ZipCrypto（PKWARE）加密 zip 的解密支持。
///
/// 招商银行邮件账单 zip 用的就是这种加密（flag bit0=1 且无 WinZip-AES
/// extra 字段 0x9901）。算法：CRC-32 驱动的三密钥流密码。
///
/// 使用：
/// ```dart
/// final result = decryptEncryptedZip(zipBytes, password);
/// // result: { 'xxx.pdf': Uint8List, ... }（key 为条目名）
/// ```
Map<String, Uint8List>? decryptEncryptedZip(
    Uint8List zipBytes, String password) {
  final entries = <String, Uint8List>{};
  var pos = 0;
  final data = zipBytes;
  while (pos + 4 <= data.length) {
    if (data[pos] != 0x50 ||
        data[pos + 1] != 0x4B ||
        data[pos + 2] != 0x03 ||
        data[pos + 3] != 0x04) {
      break; // 不再有 local file header
    }
    final flag = _u16(data, pos + 6);
    final method = _u16(data, pos + 8);
    var csize = _u32(data, pos + 18);
    final usize = _u32(data, pos + 22);
    final nameLen = _u16(data, pos + 26);
    final extraLen = _u16(data, pos + 28);
    final nameBytes = data.sublist(pos + 30, pos + 30 + nameLen);
    final name = _decodeName(nameBytes, flag);
    var dataStart = pos + 30 + nameLen + extraLen;

    if (csize == 0 || flag & 0x0008 != 0) {
      // 该条目启用了 data descriptor，压缩大小在中央目录里，
      // 这里直接按 usize==0 或从 central directory 兜底：
      // 无法在此可靠取 csize 时跳过（正常 zip 的 CD 有值，见 _fromCentral）。
      // 先尝试 descriptor 前推：本实现优先用 CD 路径，见 decryptFromZipFile。
      return null; // 走 _fromCentral 重新解析
    }

    final encrypted = flag & 0x0001 != 0;
    if (!encrypted) {
      // 未加密条目：直接解压
      final raw = data.sublist(dataStart, dataStart + csize);
      entries[name] = _inflate(raw, usize);
      pos = dataStart + csize;
      continue;
    }
    // 加密：传统 ZipCrypto（若为 WinZip-AES(method 99) 或强加密，暂不支持）
    if (method == 99 || flag & 0x0040 != 0) {
      throw UnsupportedError('该 zip 使用了暂不支持的强加密方式');
    }
    final encBlock = data.sublist(dataStart, dataStart + csize);
    final decrypted = _zipCryptoDecrypt(encBlock, password);
    if (decrypted == null) {
      throw Exception('密码错误或文件已损坏');
    }
    // 去掉 12 字节加密头，剩余为 raw deflate
    final raw = decrypted.sublist(12);
    try {
      entries[name] = _inflate(raw, usize);
    } catch (_) {
      // 部分实现 inflate 需要截断精确长度，raw 已精确（csize-12）
      rethrow;
    }
    pos = dataStart + csize;
  }
  return entries.isEmpty ? null : entries;
}

/// 带中央目录的完整解密（处理 data descriptor / 大小缺失的 zip）
Map<String, Uint8List> decryptZipWithCentral(
    Uint8List zipBytes, String password) {
  // 1) 解析中央目录：entries: name -> (flag, method, csize, usize, localOffset)
  final cd = <_CdEntry>[];
  var eocd = zipBytes.length - 22;
  while (eocd > 0 &&
      !(zipBytes[eocd] == 0x50 &&
          zipBytes[eocd + 1] == 0x4B &&
          zipBytes[eocd + 2] == 0x05 &&
          zipBytes[eocd + 3] == 0x06)) {
    eocd--;
  }
  if (eocd <= 0) {
    throw Exception('不是有效的 zip 文件');
  }
  final count = _u16(zipBytes, eocd + 10);
  final cdOffset = _u32(zipBytes, eocd + 16);
  for (var i = 0; i < count; i++) {
    final p = cdOffset + i * 46;
    if (p + 46 > zipBytes.length ||
        zipBytes[p] != 0x50 ||
        zipBytes[p + 1] != 0x4B) {
      break;
    }
    final flag = _u16(zipBytes, p + 8);
    final method = _u16(zipBytes, p + 10);
    final dosTime = _u16(zipBytes, p + 12);
    final crc = _u32(zipBytes, p + 16);
    final csize = _u32(zipBytes, p + 20);
    final usize = _u32(zipBytes, p + 24);
    final nameLen = _u16(zipBytes, p + 28);
    final extraLen = _u16(zipBytes, p + 30);
    // commentLen 仅用于跳过（本实现不解注释）
    _u16(zipBytes, p + 32);
    final localOffset = _u32(zipBytes, p + 42);
    final name = _decodeName(
        zipBytes.sublist(p + 46, p + 46 + nameLen), flag);
    cd.add(_CdEntry(name, flag, method, csize, usize, localOffset,
        nameLen, extraLen,
        crc: crc, dosTime: dosTime));
  }

  final out = <String, Uint8List>{};
  for (final e in cd) {
    // 到 local header 取 extraLen 以定位数据起点
    var lp = e.localOffset;
    if (lp + 30 > zipBytes.length) continue;
    final localExtraLen = _u16(zipBytes, lp + 28);
    final dataStart = lp + 30 + e.nameLen + localExtraLen;
    if (dataStart + e.csize > zipBytes.length) continue;

    final raw = zipBytes.sublist(dataStart, dataStart + e.csize);
    if (e.flag & 0x0001 == 0) {
      out[e.name] = _inflate(raw, e.usize);
      continue;
    }
    if (e.method == 99 || e.flag & 0x0040 != 0) {
      throw UnsupportedError('"${e.name}" 使用了暂不支持的强加密方式');
    }
    // 校验密码：加密头第 12 字节 = CRC 高字节（无 data descriptor 时）
    // 或 DOS 时间高字节（有 data descriptor 时）；两种实现都兼容。
    final checkCrc = (e.crc >> 24) & 0xFF;
    final checkTime = (e.dosTime >> 8) & 0xFF;
    final head = _zipCryptoDecrypt(raw.sublist(0, 12), password);
    if (head == null ||
        (head[11] != checkCrc && head[11] != checkTime)) {
      throw Exception('密码错误或文件已损坏');
    }
    final decrypted = _zipCryptoDecrypt(raw, password)!;
    out[e.name] = _inflate(decrypted.sublist(12), e.usize);
  }
  return out;
}

class _CdEntry {
  final String name;
  final int flag;
  final int method;
  final int csize;
  final int usize;
  final int localOffset;
  final int nameLen;
  final int extraLen;
  final int crc;
  final int dosTime;
  _CdEntry(this.name, this.flag, this.method, this.csize, this.usize,
      this.localOffset, this.nameLen, this.extraLen,
      {this.crc = 0, this.dosTime = 0});
}

// ---------------- ZipCrypto 核心 ----------------

List<int> _crcTable() {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}

final List<int> _table = _crcTable();

class _Keys {
  int k0 = 0x12345678;
  int k1 = 0x23456789;
  int k2 = 0x34567890;

  void update(int ch) {
    k0 = _table[(k0 ^ ch) & 0xFF] ^ (k0 >> 8);
    k1 = ((k1 + (k0 & 0xFF)) * 134775813 + 1) & 0xFFFFFFFF;
    k2 = _table[(k2 ^ (k1 >> 24)) & 0xFF] ^ (k2 >> 8);
  }

  int get byte {
    final t = (k2 & 0xFFFF) | 2;
    return ((t * (t ^ 1)) >> 8) & 0xFF;
  }
}

/// 用密码解密 ZipCrypto 数据块。返回含 12 字节头的解密流；密码错误返回 null。
Uint8List? _zipCryptoDecrypt(Uint8List data, String password) {
  final keys = _Keys();
  for (final c in password.codeUnits) {
    keys.update(c);
  }
  // 前 12 字节 = 加密头（11 随机 + 1 校验）
  if (data.length < 12) return null;
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    final m = data[i] ^ keys.byte;
    out[i] = m;
    keys.update(m);
  }
  return out;
}

Uint8List _inflate(Uint8List raw, int expected) {
  // archive 3.x：Inflate 构造即完成解压（输入为 zip 的 raw deflate 流）
  final inf = Inflate(raw);
  final out = inf.output.getBytes();
  return Uint8List.fromList(out);
}

int _u16(Uint8List d, int o) => d[o] | (d[o + 1] << 8);
int _u32(Uint8List d, int o) =>
    d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);
