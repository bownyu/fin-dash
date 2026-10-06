import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../data/backup.dart';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import 'chat_image_storage.dart';

const _maxAttachmentBytes = 64 * 1024 * 1024;

class BackupBundle {
  final ImportPreview preview;
  final Map<String, Uint8List> images;
  const BackupBundle(this.preview, this.images);
}

Future<String> exportBackupBundle(
  WalletStore store,
  ChatImageStorage images, {
  bool includeImages = true,
}) async {
  final data = store.data;
  if (!includeImages) return compute(_encodeBundle, (data, null));
  final ids = data.chats.map((m) => m['imageId']).whereType<String>().toSet();
  final attachments = <String, Uint8List>{};
  var total = 0;
  for (final id in ids) {
    if (!validChatImageId(id)) throw const FormatException('聊天图片引用无效');
    final bytes = await images.read(id);
    if (bytes == null) {
      throw const FormatException('部分历史图片已不在本机。可取消“包含聊天图片”后导出文字账本。');
    }
    total += bytes.length;
    if (total > _maxAttachmentBytes) {
      throw const FormatException('图片附件超过 64 MB，请取消包含图片，或先清理较旧的图片。');
    }
    attachments[id] = bytes;
  }
  return compute(_encodeBundle, (data, attachments));
}

String _encodeBundle((WalletData, Map<String, Uint8List>?) input) {
  final (data, images) = input;
  final snapshot = removeSecrets(data.toJson()) as Json;
  snapshot['exportDate'] = DateTime.now().toIso8601String();
  if (images != null) {
    snapshot['chatImages'] = {
      for (final entry in images.entries)
        entry.key: _encodeImage(entry.key, entry.value),
    };
  }
  return jsonEncode(snapshot);
}

String _encodeImage(String id, Uint8List bytes) {
  if (sha256.convert(bytes).toString() != id) {
    throw const FormatException('聊天图片校验失败，未生成完整备份');
  }
  return base64Encode(bytes);
}

Future<BackupBundle> parseBackupBundleAsync(Uint8List bytes) =>
    compute(_parseBundleBytes, bytes);
BackupBundle _parseBundleBytes(Uint8List bytes) =>
    parseBackupBundle(utf8.decode(bytes));

BackupBundle parseBackupBundle(String raw) {
  if (raw.length > 128 * 1024 * 1024) {
    throw const FormatException('备份文件超过 128 MB');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(raw.trim().replaceFirst('\uFEFF', ''));
  } on FormatException {
    // Legacy Base64 backups have no inline image attachments.
    return BackupBundle(parseBackup(raw), const {});
  }
  if (decoded is! Map) throw const FormatException('备份结构不正确');
  final preview = parseBackupObject(decoded);
  if (decoded['chatImages'] == null) {
    return BackupBundle(preview, const {});
  }
  final attachments = decoded['chatImages'];
  if (attachments is! Map) throw const FormatException('图片附件格式无效');
  final referenced = preview.data.chats
      .map((m) => m['imageId'])
      .whereType<String>()
      .toSet();
  final images = <String, Uint8List>{};
  var total = 0;
  for (final entry in attachments.entries) {
    if (entry.key is! String ||
        !validChatImageId(entry.key) ||
        !referenced.contains(entry.key) ||
        entry.value is! String) {
      throw const FormatException('图片附件包含无效引用');
    }
    if ((entry.value as String).length > _maxAttachmentBytes * 4 ~/ 3 + 4) {
      throw const FormatException('图片附件过大');
    }
    final bytes = base64Decode(entry.value);
    total += bytes.length;
    if (total > _maxAttachmentBytes ||
        sha256.convert(bytes).toString() != entry.key) {
      throw const FormatException('图片附件校验失败或超过 64 MB');
    }
    images[entry.key] = bytes;
  }
  return BackupBundle(preview, images);
}
