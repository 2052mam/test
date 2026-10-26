import 'dart:async';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  AudioPlayer? _playerSent;
  AudioPlayer? _playerReceived;
  AudioPlayer? _playerReaction;
  bool _initialized = false;
  bool _enabled = true;

  bool get isEnabled => _enabled;

  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool('sound_effects_enabled') ?? true;

      _playerSent = AudioPlayer();
      _playerReceived = AudioPlayer();
      _playerReaction = AudioPlayer();

      await Future.wait([
        _playerSent!.setAsset('assets/sounds/message_sent.wav').catchError((_) {}),
        _playerReceived!.setAsset('assets/sounds/message_received.wav').catchError((_) {}),
        _playerReaction!.setAsset('assets/sounds/reaction_pop.wav').catchError((_) {}),
      ]);
      _initialized = true;
    } catch (_) {
      // In tests or headless environments, audio drivers may not be available.
      _initialized = true;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('sound_effects_enabled', enabled);
    } catch (_) {}
  }

  Future<void> playMessageSent() async {
    if (!_enabled) return;
    try {
      HapticFeedback.lightImpact();
      if (_playerSent != null) {
        await _playerSent!.seek(Duration.zero);
        await _playerSent!.play();
      } else {
        SystemSound.play(SystemSoundType.click);
      }
    } catch (_) {
      SystemSound.play(SystemSoundType.click);
    }
  }

  Future<void> playMessageReceived() async {
    if (!_enabled) return;
    try {
      HapticFeedback.selectionClick();
      if (_playerReceived != null) {
        await _playerReceived!.seek(Duration.zero);
        await _playerReceived!.play();
      }
    } catch (_) {}
  }

  Future<void> playReaction() async {
    if (!_enabled) return;
    try {
      HapticFeedback.selectionClick();
      if (_playerReaction != null) {
        await _playerReaction!.seek(Duration.zero);
        await _playerReaction!.play();
      }
    } catch (_) {}
  }

  void dispose() {
    _playerSent?.dispose();
    _playerReceived?.dispose();
    _playerReaction?.dispose();
    _initialized = false;
  }
}
