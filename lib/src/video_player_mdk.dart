// Copyright 2022-2024 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';
// import 'dart:io';
import 'package:flutter/widgets.dart'; //
import 'package:flutter/services.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:logging/logging.dart';
import 'fvp_platform_interface.dart';
import 'extensions.dart';
import 'media_info.dart';

import '../mdk.dart' as mdk;

 
class MdkVideoPlayer extends VideoPlayerPlatform {
  static final _players = <int, mdk.Player>{};
  static final _streamCtl = <int, StreamController<VideoEvent>>{};
  static dynamic _options;
 
  static Map<String, Object>? _globalOpts;
  static Map<String, String>? _playerOpts;
  static int? _maxWidth;
  static int? _maxHeight;
  static bool? _fitMaxSize;
  static bool? _tunnel;
  static String? _subtitleFontFile;
  static int _lowLatency = 0;
  static int _seekFlags = mdk.SeekFlag.fromStart | mdk.SeekFlag.inCache;
  static List<String>? _decoders;
  static final _mdkLog = Logger('mdk');
  // _prevImpl: required if registerWith() can be invoked multiple times by user
  static VideoPlayerPlatform? _prevImpl;

  static bool isAndroidEmulator() {
    if (!Platform.isAndroid) return false;
    return Platform.environment.containsKey('ANDROID_EMULATOR');
  }

/*
  Registers this class as the default instance of [VideoPlayerPlatform].

  [options] can be
  "video.decoders": a list of decoder names. supported decoders: https://github.com/wang-bin/mdk-sdk/wiki/Decoders
  "maxWidth", "maxHeight": texture max size. if not set, video frame size is used. a small value can reduce memory cost, but may result in lower image quality.
 */
  static void registerVideoPlayerPlatformsWith({dynamic options}) {
    _log.fine('registerVideoPlayerPlatformsWith: $options');
    if (options is Map<String, dynamic>) {
      final platforms = options['platforms'];
      if (platforms is List<String>) {
        if (!platforms.contains(Platform.operatingSystem)) {
          if (_prevImpl != null &&
              VideoPlayerPlatform.instance is MdkVideoPlayerPlatform) {
            // null if it's the 1st time to call registerWith() including current platform
            // if current is not MdkVideoPlayerPlatform, another plugin may set instance
            // if current is MdkVideoPlayerPlatform, we have to restore instance,  _prevImpl is correct and no one changed instance
            VideoPlayerPlatform.instance = _prevImpl!;
          }
          return;
        }
      }
 
      if (!isAndroidEmulator()) {
        _options.putIfAbsent(
            'video.decoders', () => vd[Platform.operatingSystem]!);
 
      }
      _lowLatency = (options['lowLatency'] ?? 0) as int;
      _maxWidth = options["maxWidth"];
      _maxHeight = options["maxHeight"];
      _fitMaxSize = options["fitMaxSize"];
      _tunnel = options["tunnel"];
      _playerOpts = options['player'];
      _globalOpts = options['global'];
      _decoders = options['video.decoders'];
      _subtitleFontFile = options['subtitleFontFile'];
    }

    if (_decoders == null && !PlatformEx.isAndroidEmulator()) {
      // prefer hardware decoders
      const vd = {
        'windows': ['MFT:d3d=11', "D3D11", "DXVA", 'CUDA', 'FFmpeg'],
        'macos': ['VT', 'FFmpeg'],
        'ios': ['VT', 'FFmpeg'],
        'linux': ['VAAPI', 'CUDA', 'VDPAU', 'FFmpeg'],
        'android': ['AMediaCodec', 'FFmpeg'],
      };
      _decoders = vd[Platform.operatingSystem];
    }

// delay: ensure log handler is set in main(), blank window if run with debugger.
// registerWith() can be invoked by dart_plugin_registrant.dart before main. when debugging, won't enter main if posting message from native to dart(new native log message) before main?
    Future.delayed(const Duration(milliseconds: 0), () {
      _setupMdk();
    });

    _prevImpl ??= VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = MdkVideoPlayerPlatform();
  }

  static void _setupMdk() {
    mdk.setLogHandler((level, msg) {
      if (msg.endsWith('\n')) {
        msg = msg.substring(0, msg.length - 1);
      }
      switch (level) {
        case mdk.LogLevel.error:
          _mdkLog.severe(msg);
        case mdk.LogLevel.warning:
          _mdkLog.warning(msg);
        case mdk.LogLevel.info:
          _mdkLog.info(msg);
        case mdk.LogLevel.debug:
          _mdkLog.fine(msg);
        case mdk.LogLevel.all:
          _mdkLog.finest(msg);
        default:
          return;
      }
    });
    // mdk.setGlobalOptions('plugins', 'mdk-braw');
    mdk.setGlobalOption("log", "all");
    mdk.setGlobalOption('d3d11.sync.cpu', 1);
    mdk.setGlobalOption('subtitle.fonts.file',
        PlatformEx.assetUri(_subtitleFontFile ?? 'assets/subfont.ttf'));
    _globalOpts?.forEach((key, value) {
      mdk.setGlobalOption(key, value);
    });
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int playerId) async {
    _players.remove(playerId)?.dispose();
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    final uri = _toUri(dataSource);
    final player = MdkVideoPlayer();
    _log.fine('$hashCode player${player.nativeHandle} create($uri)');
 
    player.setProperty(
        'avio.protocol_whitelist', 'file,http,https,tcp,tls,crypto');
 
    _playerOpts?.forEach((key, value) {
      player.setProperty(key, value);
    });

 
    if (_options is Map<String, dynamic> &&
        _options.containsKey('video.decoders')) {
      player.videoDecoders = _options['video.decoders'];
 
    }

    if (dataSource.httpHeaders.isNotEmpty) {
      String headers = '';
      dataSource.httpHeaders.forEach((key, value) {
        headers += '$key: $value\r\n';
      });
      player.setProperty('avio.headers', headers);
    }
    player.media = uri;
    int ret = await player.prepare(); // required!
    if (ret < 0) {
      // no throw, handle error in controller.addListener
      _players[-hashCode] = player;
      player.streamCtl.addError(PlatformException(
        code: 'media open error',
        message: 'invalid or unsupported media',
      ));
      //player.dispose(); // dispose for throw
      return -hashCode;
    }
// FIXME: pending events will be processed after texture returned, but no events before prepared
 
    final tex = await player.updateTexture(
        width: _maxWidth, height: _maxHeight, fit: _fitMaxSize);
 
    if (tex < 0) {
      _players[-hashCode] = player;
      player.streamCtl.addError(PlatformException(
        code: 'video size error',
        message: 'invalid or unsupported media with invalid video size',
      ));
      //player.dispose();
      return -hashCode;
    }
    _log.fine('$hashCode player${player.nativeHandle} textureId=$tex');
    _players[tex] = player;
    return tex;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {
    final player = _players[playerId];
    if (player != null) {
      player.loop = looping ? -1 : 0;
    }
  }

  @override
  Future<void> play(int playerId) async {
    _players[playerId]?.state = mdk.PlaybackState.playing;
  }

  @override
  Future<void> pause(int playerId) async {
    _players[playerId]?.state = mdk.PlaybackState.paused;
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    _players[playerId]?.volume = volume;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    _players[playerId]?.playbackRate = speed;
  }

  @override
 
  Future<void> seekTo(int textureId, Duration position) async {
    final player = _players[textureId];
    if (player != null) {
      player.seek(
          position: position.inMilliseconds,
          flags: const mdk.SeekFlag(mdk.SeekFlag.fromStart |
              mdk.SeekFlag.keyFrame |
              mdk.SeekFlag.inCache));
    }
 
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    final player = _players[playerId];
    if (player == null) {
      return Duration.zero;
    }
    final pos = player.position;
    final bufLen = player.buffered();
 
    sc?.add(VideoEvent(eventType: VideoEventType.bufferingUpdate, buffered: [
      DurationRange(
          Duration(microseconds: pos), Duration(milliseconds: pos + bufLen))
    ]));
 
    return Duration(milliseconds: pos);
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    final player = _players[playerId];
    if (player != null) {
      return player.streamCtl.stream;
    }
    throw Exception('No Stream<VideoEvent> for textureId: $playerId.');
  }

  @override
  Widget buildView(int playerId) {
    return Texture(textureId: playerId);
  }

  @override
 
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  StreamController<VideoEvent> _initEvents(mdk.Player player) {
    final sc = StreamController<VideoEvent>();
    player.onMediaStatusChanged((oldValue, newValue) {
      _log.fine(
          '$hashCode player${player.nativeHandle} onMediaStatusChanged: $oldValue => $newValue');
      if (!oldValue.test(mdk.MediaStatus.loaded) &&
          newValue.test(mdk.MediaStatus.loaded)) {
        final info = player.mediaInfo;
        var size = const Size(0, 0);
        if (info.video != null) {
          final vc = info.video![0].codec;
          size = Size(vc.width.toDouble(), vc.height.toDouble());
        }
        sc.add(VideoEvent(
            eventType: VideoEventType.initialized,
            duration: Duration(
                milliseconds: info.duration == 0
                    ? double.maxFinite.toInt()
                    : info
                        .duration) // FIXME: live stream info.duraiton == 0 and result a seekTo(0) in play()
            ,
            size: size));
      } else if (!oldValue.test(mdk.MediaStatus.buffering) &&
          newValue.test(mdk.MediaStatus.buffering)) {
        sc.add(VideoEvent(eventType: VideoEventType.bufferingStart));
      } else if (!oldValue.test(mdk.MediaStatus.buffered) &&
          newValue.test(mdk.MediaStatus.buffered)) {
        sc.add(VideoEvent(eventType: VideoEventType.bufferingEnd));
      }
      return true;
    });

    player.onEvent((ev) {
      _log.fine(
          '$hashCode player${player.nativeHandle} onEvent: ${ev.category} ${ev.error}');
      if (ev.category == "reader.buffering") {
        final pos = player.position;
        final bufLen = player.buffered();
        sc.add(VideoEvent(eventType: VideoEventType.bufferingUpdate, buffered: [
          DurationRange(
              Duration(microseconds: pos), Duration(milliseconds: pos + bufLen))
        ]));
 
      }
    }
    player.seek(position: position.inMilliseconds, flags: flags);
  }

 
    player.onStateChanged((oldValue, newValue) {
      _log.fine(
          '$hashCode player${player.nativeHandle} onPlaybackStateChanged: $oldValue => $newValue');
      sc.add(VideoEvent(
          eventType: VideoEventType.isPlayingStateUpdate,
          isPlaying: newValue == mdk.PlaybackState.playing));
    });
    return sc;
  }

  static String _assetUri(String asset, String? package) {
    final key = asset;
    switch (Platform.operatingSystem) {
      case 'windows':
        return path.join(path.dirname(Platform.resolvedExecutable), 'data',
            'flutter_assets', key);
      case 'linux':
        return path.join(path.dirname(Platform.resolvedExecutable), 'data',
            'flutter_assets', key);
      case 'macos':
        return path.join(path.dirname(Platform.resolvedExecutable), '..',
            'Frameworks', 'App.framework', 'Resources', 'flutter_assets', key);
      case 'ios':
        return path.join(path.dirname(Platform.resolvedExecutable),
            'Frameworks', 'App.framework', 'flutter_assets', key);
      case 'android':
        return 'assets://flutter_assets/$key';
 
    }
  }
}
