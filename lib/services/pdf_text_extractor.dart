import 'dart:typed_data';

import 'package:pdfrx_engine/pdfrx_engine.dart';

/// 用 pdfrx_engine（pdfium）从 PDF 提取全文文本。
/// 返回逐页拼接的文本（页间以换行分隔），供账单行解析器使用。
Future<String> extractPdfText(Uint8List pdfBytes) async {
  final doc = await PdfDocument.openData(
    pdfBytes,
    sourceName: 'bill.pdf',
    firstAttemptByEmptyPassword: true,
  );
  try {
    final buf = StringBuffer();
    final pages = doc.pages;
    for (var i = 0; i < pages.length; i++) {
      final raw = await pages[i].loadText();
      final t = raw?.fullText ?? '';
      if (t.isNotEmpty) {
        buf.write(t);
        buf.write('\n');
      }
    }
    return buf.toString();
  } finally {
    await doc.dispose();
  }
}
