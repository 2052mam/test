import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/app_locale.dart';
import '../../../data/models/user_model.dart';
import '../../../data/services/api_service.dart';
import '../../../data/services/device_service.dart';
import '../../providers/auth_provider.dart';

/// The optional Google Authenticator step. New phone-first logins pass a
/// verified challenge ID; email/password is retained only for legacy accounts.
class TwoFactorScreen extends ConsumerStatefulWidget {
  final String? email;
  final String? password;
  final String? verificationId;

  const TwoFactorScreen({
    super.key,
    this.email,
    this.password,
    this.verificationId,
  }) : assert(
         verificationId != null || (email != null && password != null),
         'Provide an SMS verification ID or legacy email/password credentials.',
       );

  bool get isPhoneLogin => verificationId != null;

  @override
  ConsumerState<TwoFactorScreen> createState() => _TwoFactorScreenState();
}

class _TwoFactorScreenState extends ConsumerState<TwoFactorScreen> {
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading) return;
    final code = _codeCtrl.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = AppLocale.pick('کد ۶ رقمی وارد کنید', 'Enter the six-digit code.'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = widget.isPhoneLogin
          ? await ApiService().post('/auth/verify-login-2fa', {
              'verification_id': widget.verificationId,
              'code': code,
              'device_info': await DeviceService.getDeviceInfo(),
            })
          : await ApiService().post('/auth/login', {
              'email': widget.email,
              'password': widget.password,
              'totp_code': code,
              'device_info': await DeviceService.getDeviceInfo(),
            });
      if (!mounted) return;
      final user = UserModel.fromJson(response['user'] as Map<String, dynamic>);
      await ref.read(authNotifierProvider.notifier).setLoggedIn(
            user,
            response['access_token'] as String,
            response['refresh_token'] as String? ?? '',
          );
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = AppLocale.pick('خطا در ورود', 'Could not sign in.'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocale.pick('تأیید دو مرحله‌ای', 'Two-step verification'), style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFF2AABEE),
                        primary,
                      ],
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
                  child: const Icon(Icons.shield_rounded, size: 42, color: Colors.white),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                widget.isPhoneLogin
                    ? AppLocale.pick('پیامک تأیید شد. کد Google Authenticator را وارد کنید', 'SMS verified. Enter your Google Authenticator code.')
                    : AppLocale.pick('کد Google Authenticator را وارد کنید', 'Enter your Google Authenticator code.'),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _codeCtrl,
                keyboardType: TextInputType.number,
                maxLength: 6,
                autofocus: true,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 32,
                  letterSpacing: 14,
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  labelText: AppLocale.pick('کد ۶ رقمی', 'Six-digit code'),
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
                onSubmitted: (_) => _submit(),
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
              const SizedBox(height: 24),
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: _loading ? null : _submit,
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
                          AppLocale.pick('تأیید', 'Verify'),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
