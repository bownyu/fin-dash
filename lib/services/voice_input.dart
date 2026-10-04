import 'package:flutter/services.dart';

class VoiceInput {
  static const channel = MethodChannel('findash/voice');

  /// [onLevel] receives microphone loudness from 0 to 1 about ten times a second.
  Future<String?> listen({
    void Function(String)? onPartial,
    void Function(String)? onState,
    void Function(double)? onLevel,
  }) async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'partial') onPartial?.call(call.arguments as String);
      if (call.method == 'state') onState?.call(call.arguments as String);
      if (call.method == 'level') {
        onLevel?.call((call.arguments as num).toDouble());
      }
    });
    try {
      return await channel.invokeMethod<String>('start');
    } on MissingPluginException {
      throw const FormatException('当前设备不支持语音识别，可以直接输入记账内容');
    } on PlatformException catch (e) {
      throw FormatException(e.message ?? '语音识别失败，可以重试或编辑已识别文字');
    } finally {
      channel.setMethodCallHandler(null);
    }
  }

  Future<void> stop() async {
    try {
      await channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      /* No native recording on this platform. */
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
