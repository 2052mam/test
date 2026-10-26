import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/utils/app_locale.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/user_model.dart';
import '../../../data/services/api_service.dart';
import '../../../data/services/device_service.dart';
import '../../providers/auth_provider.dart';
import 'support_contact_sheet.dart';
import 'two_factor_screen.dart';

enum PhoneVerificationFlow { registration, login }

/// Telegram-style code entry for both registration and phone-first login.
/// Redesigned with countdown timer ring, OTP styling, and smooth feedback.
class PhoneVerificationScreen extends ConsumerStatefulWidget {
  final String verificationId;
  final String mobileNumber;
  final PhoneVerificationFlow flow;

  /// 'in_app' when the code was delivered to another signed-in device,
  /// 'sms' otherwise. Comes straight from the request-code response.
  final String deliveryChannel;

  /// Seconds until the code may be resent. The server's resend cooldown.
  final int resendAfterSeconds;

  const PhoneVerificationScreen({
    super.key,
    required this.verificationId,
    required this.mobileNumber,
    required this.flow,
    this.deliveryChannel = 'sms',
    this.resendAfterSeconds = 300,
  });

  @override
  ConsumerState<PhoneVerificationScreen> createState() =>
      _PhoneVerificationScreenState();
}

class _PhoneVerificationScreenState
    extends ConsumerState<PhoneVerificationScreen> {
  final _codeCtrl = TextEditingController();
  late String _verificationId;
  late String _channel;
  bool _loading = false;
  bool _resending = false;
  String? _error;
  String? _message;

  Timer? _ticker;
  int _secondsLeft = 0;

  @override
  void initState() {
    super.initState();
    _verificationId = widget.verificationId;
    _channel = widget.deliveryChannel;
    _startCountdown(widget.resendAfterSeconds);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    _ticker?.cancel();
    final total = seconds <= 0 ? 0 : seconds;
    setState(() => _secondsLeft = total);
    if (total == 0) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_secondsLeft <= 1) {
        timer.cancel();
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft -= 1);
      }
    });
  }

  String get _countdownLabel {
    final minutes = (_secondsLeft ~/ 60).toString().padLeft(2, '0');
    final seconds = (_secondsLeft % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  bool get _inApp => _channel == 'in_app';

  Future<void> _verify() async {
    if (_loading) return;
    final code = _codeCtrl.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = AppLocale.pick('کد ۶ رقمی را وارد کنید', 'Enter the 6-digit code.'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _message = null;
    });
    try {
      final response = await ApiService().post('/auth/verify-phone', {
        'verification_id': _verificationId,
        'code': code,
        'device_info': await DeviceService.getDeviceInfo(),
      });
      if (!mounted) return;
      if (response['require_2fa'] == true) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => TwoFactorScreen(
              verificationId: response['verification_id'] as String,
            ),
          ),
        );
        return;
      }
      await _saveSession(response);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = AppLocale.pick('خطا در تأیید کد', 'Could not verify the code.'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveSession(Map<String, dynamic> response) async {
    final user = UserModel.fromJson(response['user'] as Map<String, dynamic>);
    await ref.read(authNotifierProvider.notifier).setLoggedIn(
          user,
          response['access_token'] as String,
          response['refresh_token'] as String? ?? '',
        );
  }

  Future<void> _resend({bool forceSms = false}) async {
    if (_loading || _resending) return;
    if (_secondsLeft > 0 && !forceSms) return;
    setState(() {
      _resending = true;
      _error = null;
      _message = null;
    });
    try {
      final response = await ApiService().post('/auth/resend-phone-code', {
        'verification_id': _verificationId,
        if (forceSms) 'force_sms': true,
      });
      if (!mounted) return;
      final channel = response['delivery_channel'] as String? ?? 'sms';
      setState(() {
        _verificationId =
            response['verification_id'] as String? ?? _verificationId;
        _channel = channel;
        _codeCtrl.clear();
        _message = channel == 'in_app'
            ? AppLocale.pick('کد جدید به دستگاه دیگری که با آن وارد شده‌اید ارسال شد.', 'A new code was sent to another device signed in to your account.')
            : AppLocale.pick('کد جدید پیامک شد.', 'A new code was sent by SMS.');
      });
      _startCountdown(
        (response['resend_after_seconds'] as num?)?.toInt() ?? widget.resendAfterSeconds,
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
      final retryAfter = error.details['retry_after_seconds'];
      if (retryAfter is num) _startCountdown(retryAfter.toInt());
    } catch (_) {
      if (mounted) setState(() => _error = AppLocale.pick('ارسال دوباره کد ممکن نیست', 'Could not resend the code.'));
    } finally {
      if (mounted) setState(() => _resending = false);
    }
  }

  Future<void> _contactSupport() async {
    final sent = await showSupportContactSheet(
      context,
      mobileNumber: widget.mobileNumber,
      initialTopic: 'code_not_received',
    );
    if (sent && mounted) {
      setState(() => _message =
          AppLocale.pick('پیام شما برای پشتیبانی ثبت شد. به‌زودی با شما تماس گرفته می‌شود.', 'Your message was sent to support. We will get back to you soon.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final registering = widget.flow == PhoneVerificationFlow.registration;
    final waiting = _secondsLeft > 0;
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          registering ? AppLocale.pick('تأیید شماره موبایل', 'Verify mobile number') : AppLocale.pick('ورود با شماره موبایل', 'Sign in with mobile number'),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: _inApp
                            ? [const Color(0xFF00ACC1), const Color(0xFF2481CC)]
                            : [const Color(0xFF2AABEE), const Color(0xFF1D70B8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: primary.withValues(alpha: 0.3),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Icon(
                      _inApp ? Icons.forum_rounded : Icons.sms_rounded,
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  registering
                      ? AppLocale.pick('شماره خود را تأیید کنید', 'Verify your number')
                      : AppLocale.pick('کد ورود را وارد کنید', 'Enter your sign-in code'),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  _inApp
                      ? AppLocale.pick('کد ۶ رقمی را در برنامه‌ی دستگاه دیگری که با شماره ${widget.mobileNumber} وارد شده‌اید فرستادیم.', 'We sent a 6-digit code to another device signed in with ${widget.mobileNumber}.')
                      : AppLocale.pick('کد ۶ رقمی به ${widget.mobileNumber} پیامک شد.', 'A 6-digit code was sent by SMS to ${widget.mobileNumber}.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: theme.textTheme.bodySmall?.color,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                if (_inApp) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: primary.withValues(alpha: 0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline_rounded, size: 20, color: primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            AppLocale.pick('برنامه روی دستگاه قبلی خود را باز کنید و کد را در بخش اعلان‌ها یا چت سرویس بخوانید.', 'Open Reyno on your other device and find the code in notifications or the service chat.'),
                            style: TextStyle(
                              fontSize: 12.5,
                              color: theme.textTheme.bodyMedium?.color,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                TextField(
                  controller: _codeCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 14,
                  ),
                  decoration: InputDecoration(
                    labelText: AppLocale.pick('کد تأیید ۶ رقمی', '6-digit verification code'),
                    counterText: '',
                    hintText: '• • • • • •',
                    hintStyle: TextStyle(
                      color: Colors.grey.shade400,
                      letterSpacing: 10,
                      fontSize: 26,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: (_) => _verify(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
                if (_message != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      _message!,
                      style: const TextStyle(color: Colors.green, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _verify,
                    style: ElevatedButton.styleFrom(
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            registering ? AppLocale.pick('تأیید', 'Verify') : AppLocale.pick('ورود', 'Sign in'),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
                const SizedBox(height: 18),
                if (waiting)
                  Container(
                    key: const ValueKey('resend-countdown'),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      AppLocale.pick('ارسال دوباره کد تا $_countdownLabel دیگر', 'Resend code in $_countdownLabel'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.textTheme.bodySmall?.color,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                else
                  TextButton.icon(
                    key: const ValueKey('resend-button'),
                    onPressed: _resending ? null : () => _resend(),
                    icon: _resending
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(
                      AppLocale.pick('ارسال دوباره کد', 'Resend code'),
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                if (_inApp) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('force-sms-button'),
                    onPressed: _resending ? null : () => _resend(forceSms: true),
                    icon: const Icon(Icons.sms_outlined, size: 18),
                    label: Text(AppLocale.pick('ارسال کد با پیامک', 'Send code by SMS')),
                  ),
                ],
                const SizedBox(height: 12),
                Center(
                  child: TextButton.icon(
                    key: const ValueKey('contact-support-button'),
                    icon: const Icon(Icons.support_agent_rounded, size: 18),
                    label: Text(AppLocale.pick('تماس با پشتیبانی', 'Contact support')),
                    onPressed: _contactSupport,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
