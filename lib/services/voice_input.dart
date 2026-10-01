import 'package:flutter/services.dart';

class VoiceInput {
  static const channel = MethodChannel('findash/voice');
  Future<String?> listen() async {
    try {
      return await channel.invokeMethod<String>('start');
    } on MissingPluginException {
      throw const FormatException('当前设备不支持语音识别，可以直接输入记账内容');
    } on PlatformException catch (e) {
      throw FormatException(e.message ?? '语音识别失败，请重试');
    }
  }

  Future<void> stop() async {
    try {
      await channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // There is no native recording to stop on this platform.
    } on PlatformException catch (e) {
      throw FormatException(e.message ?? '无法结束语音识别');
    }
  }

  Future<bool> pinWidget() async {
    try {
      return await channel.invokeMethod<bool>('pinWidget') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> cancel() async {
    try {
      await channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      /* Text entry remains available. */
    } on PlatformException {
      /* The activity may already have stopped. */
    }
  }
}
