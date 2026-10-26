import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/app_locale.dart';
import '../../../data/services/api_service.dart';

/// Verifies the registration phone from an authenticated session so an
/// authenticator-first account can retain a private SMS recovery route.
class PhoneRecoveryScreen extends StatefulWidget {
  const PhoneRecoveryScreen({super.key});

  @override
  State<PhoneRecoveryScreen> createState() => _PhoneRecoveryScreenState();
}

class _PhoneRecoveryScreenState extends State<PhoneRecoveryScreen> {
  final _codeCtrl = TextEditingController();
  String? _verificationId;
  String? _maskedNumber;
  String? _error;
  bool _loading = false;
  bool _verified = false;

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _requestCode() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ApiService().post(
          '/auth/request-phone-recovery-code', {});
      if (!mounted) return;
      if (response['already_verified'] == true) {
        setState(() => _verified = true);
      } else {
        setState(() {
          _verificationId = response['verification_id'] as String?;
          _maskedNumber = response['mobile_number'] as String?;
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = AppLocale.pick(
            'ارسال کد ناموفق بود.', 'Could not send the code.'));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verify() async {
    if (_loading || _verificationId == null) return;
    final code = _codeCtrl.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = AppLocale.pick(
          'کد شش‌رقمی را وارد کنید.', 'Enter the six-digit code.'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ApiService().post('/auth/verify-phone-recovery', {
        'verification_id': _verificationId,
        'code': code,
      });
      if (mounted) setState(() => _verified = true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = AppLocale.pick(
            'تأیید کد ناموفق بود.', 'Could not verify the code.'));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(AppLocale.pick(
          'شمارهٔ بازیابی', 'Recovery phone'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            AppLocale.pick(
                'شمارهٔ ثبت‌نام را با پیامک تأیید کنید تا بتوانید در صورت نداشتن دسترسی به Google Authenticator از آن به‌عنوان راه بازیابی استفاده کنید.',
                'Verify your registration phone by SMS so it can be used as a recovery route if you cannot access Google Authenticator.'),
            style: const TextStyle(fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 18),
          if (_verified)
            Card(
              child: ListTile(
                leading: const Icon(Icons.verified_user, color: Colors.green),
                title: Text(AppLocale.pick(
                    'شمارهٔ بازیابی تأیید شده است', 'Recovery phone verified')),
              ),
            )
          else if (_verificationId == null)
            FilledButton.icon(
              onPressed: _loading ? null : _requestCode,
              icon: const Icon(Icons.sms_outlined),
              label: Text(AppLocale.pick(
                  'ارسال کد تأیید پیامکی', 'Send verification SMS')),
            )
          else ...[
            Text(AppLocale.pick(
                'کد به شمارهٔ $_maskedNumber ارسال شد.',
                'A code was sent to $_maskedNumber.'),
                style: TextStyle(color: theme.textTheme.bodySmall?.color)),
            const SizedBox(height: 14),
            TextField(
              controller: _codeCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: AppLocale.pick('کد شش‌رقمی', 'Six-digit code'),
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              onPressed: _loading ? null : _verify,
              child: Text(AppLocale.pick('تأیید شماره', 'Verify phone')),
            ),
          ],
          if (_loading) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
