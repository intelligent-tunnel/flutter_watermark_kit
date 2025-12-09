import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:watermark_kit/gen/messages.g.dart' as pigeon;
import 'package:watermark_kit/watermark_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('composeVideo routes progress and completion via callbacks', () async {
    final codec = pigeon.WatermarkCallbacks.pigeonChannelCodec;

    // 模拟宿主侧启动 composeVideo 并稍后返回完成结果。
    const composeVideoChannel = 'dev.flutter.pigeon.watermark_kit.WatermarkApi.composeVideo';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(composeVideoChannel, (ByteData? message) async {
      final List<Object?>? args = codec.decodeMessage(message) as List<Object?>?;
      final req = args![0] as pigeon.ComposeVideoRequest;

      // 模拟宿主侧先发送进度回调再完成。
      Future.delayed(const Duration(milliseconds: 10), () async {
        // onVideoProgress 进度回调
        final chan = const BasicMessageChannel<Object?>(
            'dev.flutter.pigeon.watermark_kit.WatermarkCallbacks.onVideoProgress',
            StandardMessageCodec());
        // 使用与 pigeon 一致的编解码器编码消息。
        final ByteData msg1 = codec.encodeMessage(<Object?>[req.taskId!, 0.5, 1.0])!;
        // 派发到对应的通道处理器
        // ignore: invalid_use_of_protected_member
        ServicesBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          chan.name,
          msg1,
          (ByteData? _) {},
        );

        // onVideoCompleted 完成回调
        final completedChan = const BasicMessageChannel<Object?>(
            'dev.flutter.pigeon.watermark_kit.WatermarkCallbacks.onVideoCompleted',
            StandardMessageCodec());
        final res = pigeon.ComposeVideoResult(
          taskId: req.taskId!,
          outputVideoPath: '/tmp/out.mp4',
          width: 1280,
          height: 720,
          durationMs: 1000,
          codec: pigeon.VideoCodec.h264,
        );
        final ByteData msg2 = codec.encodeMessage(<Object?>[res])!;
        // ignore: invalid_use_of_protected_member
        ServicesBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          completedChan.name,
          msg2,
          (ByteData? _) {},
        );
      });

      // 返回 ComposeVideoResult（与完成回调一致）
      final ret = pigeon.ComposeVideoResult(
        taskId: req.taskId!,
        outputVideoPath: '/tmp/out.mp4',
        width: 1280,
        height: 720,
        durationMs: 1000,
        codec: pigeon.VideoCodec.h264,
      );
      return codec.encodeMessage(<Object?>[ret]);
    });

    final wm = WatermarkKit();
    final task = await wm.composeVideo(
      inputVideoPath: '/tmp/in.mp4',
      text: 'hello',
    );
    final sub = task.progress.listen((_) {});
    final res = await task.done.timeout(const Duration(seconds: 1));
    await sub.cancel();
    expect(res.path, '/tmp/out.mp4');
    expect(res.width, 1280);
    expect(res.codec, 'h264');
  });

  test('composeVideo surfaces errors when native reports failure', () async {
    final codec = pigeon.WatermarkCallbacks.pigeonChannelCodec;
    const composeVideoChannel = 'dev.flutter.pigeon.watermark_kit.WatermarkApi.composeVideo';
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMessageHandler(composeVideoChannel, (ByteData? message) async {
      final List<Object?>? args = codec.decodeMessage(message) as List<Object?>?;
      final req = args![0] as pigeon.ComposeVideoRequest;

      // 模拟宿主侧抛出错误回调但不返回 ComposeVideoResult。
      Future.microtask(() {
        const errorChan = BasicMessageChannel<Object?>(
            'dev.flutter.pigeon.watermark_kit.WatermarkCallbacks.onVideoError',
            StandardMessageCodec());
        final ByteData errMsg = codec.encodeMessage(<Object?>[
          req.taskId!,
          'compose_failed',
          'simulated failure',
        ])!;
        // ignore: invalid_use_of_protected_member
        ServicesBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          errorChan.name,
          errMsg,
          (ByteData? _) {},
        );
      });

      // 宿主侧不返回 ComposeVideoResult，仅触发错误回调。
      return null;
    });
    addTearDown(() {
      messenger.setMockMessageHandler(composeVideoChannel, null);
    });

    final wm = WatermarkKit();
    final task = await wm.composeVideo(
      inputVideoPath: '/tmp/in.mp4',
      text: 'boom',
    );

    await expectLater(
      task.done,
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'compose_failed')
            .having((e) => e.message, 'message', 'simulated failure'),
      ),
    );
  });

  test('composeVideo times out when host never replies (simulate hanging video)', () {
    fakeAsync((async) {
      const composeVideoChannel = 'dev.flutter.pigeon.watermark_kit.WatermarkApi.composeVideo';
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      // 宿主侧不返回任何结果，模拟某些视频处理卡死的场景。
      messenger.setMockMessageHandler(composeVideoChannel, (ByteData? message) {
        // 永远 pending 的 Future。
        return Completer<ByteData?>().future;
      });
      addTearDown(() {
        messenger.setMockMessageHandler(composeVideoChannel, null);
      });

      final wm = WatermarkKit();
      VideoTask? task;
      wm.composeVideo(
        inputVideoPath: 'example/assets/video2.mp4',
        text: 'timeout',
      ).then((t) => task = t);

      async.flushMicrotasks();
      expect(task, isNotNull);

      Object? error;
      task!.done.catchError((e) => error = e);

      // 触发 watchdog 超时
      async.elapse(const Duration(seconds: 15));
      async.flushMicrotasks();

      expect(error, isA<TimeoutException>());
    });
  });
}
