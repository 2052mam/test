import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/utils/app_locale.dart';
import '../../../data/models/user_model.dart';
import '../../../data/services/api_service.dart';
import '../../../data/services/device_service.dart';
import '../../providers/auth_provider.dart';

/// User-only TOTP enrollment for deployments whose administrator selected it
/// as the registration verification method. The secret is never sent to admin.
class TotpRegistrationScreen extends ConsumerStatefulWidget {
  const TotpRegistrationScreen({
    super.key,
    required this.verificationId,
    required this.secret,
    required this.uri,
  });

  final String verificationId;
  final String secret;
  final String uri;

  @override
  ConsumerState<TotpRegistrationScreen> createState() =>
      _TotpRegistrationScreenState();
}

class _TotpRegistrationScreenState
    extends ConsumerState<TotpRegistrationScreen> {
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_loading) return;
    final code = _codeCtrl.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = AppLocale.pick(
          'کد ۶ رقمی برنامه را وارد کنید', 'Enter the 6-digit code from your authenticator app.'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ApiService().post(
        '/auth/verify-totp-registration',
        {
          'verification_id': widget.verificationId,
          'code': code,
          'device_info': await DeviceService.getDeviceInfo(),
        },
      );
      final user = UserModel.fromJson(response['user'] as Map<String, dynamic>);
      await ref.read(authNotifierProvider.notifier).setLoggedIn(
            user,
            response['access_token'] as String,
            response['refresh_token'] as String? ?? '',
          );
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = AppLocale.pick(
            'تأیید کد ناموفق بود', 'Could not verify the code.'));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocale.pick(
            'راه‌اندازی Google Authenticator', 'Set up Google Authenticator')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                AppLocale.pick(
                    '۱. این QR را با Google Authenticator یا برنامه سازگار اسکن کنید.\n۲. کد شش‌رقمی فعلی را وارد کنید تا حساب فعال شود.',
                    '1. Scan this QR code with Google Authenticator or a compatible app.\n2. Enter its current six-digit code to activate your account.'),
                style: const TextStyle(fontSize: 15, height: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(14),
                  child: QrImageView(data: widget.uri, size: 210),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                AppLocale.pick('اگر اسکن ممکن نیست، کلید راه‌اندازی را دستی وارد کنید:', 'If you cannot scan the QR code, enter this setup key manually:'),
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.textTheme.bodySmall?.color),
              ),
              const SizedBox(height: 8),
              SelectableText(
                widget.secret,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2),
              ),
              Align(
                child: TextButton.icon(
                  onPressed: () => Clipboard.setData(
                      ClipboardData(text: widget.secret)),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(AppLocale.pick('کپی کلید', 'Copy setup key')),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                ),
                child: Text(
                  AppLocale.pick(
                      'این کلید فقط برای شماست؛ آن را امن نگه دارید. شماره موبایل واردشده در این روش تأیید نمی‌شود و مدیر هم به کلید یا کدهای شما دسترسی ندارد.',
                      'This setup key belongs only to you; store it securely. The phone number entered during this method is not verified. Admins cannot view your key or codes.'),
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _codeCtrl,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: AppLocale.pick('کد شش‌رقمی', 'Six-digit code'),
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 10),
              FilledButton(
                onPressed: _loading ? null : _verify,
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(AppLocale.pick('تأیید و فعال‌سازی حساب', 'Verify and activate account')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
