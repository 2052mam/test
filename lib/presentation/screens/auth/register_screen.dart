import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/app_locale.dart';
import '../../../data/services/api_service.dart';
import '../../../data/services/device_service.dart';
import '../../../data/services/terms_service.dart';
import '../../widgets/chat/terms_dialog.dart';
import 'phone_verification_screen.dart';
import 'totp_registration_screen.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key, this.initialMobileNumber});

  /// Prefilled when the login screen redirected an unregistered number here.
  final String? initialMobileNumber;

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _mobileCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;
  bool _termsAccepted = false;
  bool _registrationUsesTotp = false;

  @override
  void initState() {
    super.initState();
    final mobile = widget.initialMobileNumber?.trim();
    if (mobile != null && mobile.isNotEmpty) _mobileCtrl.text = mobile;
    _loadAuthMethods();
  }

  Future<void> _loadAuthMethods() async {
    try {
      final methods = await ApiService().get('/auth/methods');
      if (mounted) {
        setState(() => _registrationUsesTotp =
            methods['registration_method'] == 'totp');
      }
    } catch (_) {
      // SMS remains the server's fail-safe default.
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _mobileCtrl.dispose();
    _passwordCtrl.dispose();
    _usernameCtrl.dispose();
    _displayNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _showTerms() async {
    final accepted = await TermsDialog.show(context, requireAccept: true);
    if (accepted == true && mounted) setState(() => _termsAccepted = true);
  }

  Future<void> _submit() async {
    if (_loading || !_formKey.currentState!.validate()) return;
    if (!_termsAccepted) {
      setState(() => _error = AppLocale.pick('برای ثبت‌نام باید قوانین را بخوانید و بپذیرید', 'Read and accept the terms to register.'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final deviceInfo = await DeviceService.getDeviceInfo();
      final username = _usernameCtrl.text.trim().toLowerCase();
      final res = await ApiService().post('/auth/register', {
        'email': _emailCtrl.text.trim().toLowerCase(),
        'mobile_number': _mobileCtrl.text.trim(),
        'password': _passwordCtrl.text,
        if (username.isNotEmpty) 'username': username,
        'display_name': _displayNameCtrl.text.trim(),
        'device_info': deviceInfo,
        'terms_accepted': true,
        'terms_version': TermsService.currentVersion,
      });

      if (!mounted) return;
      if (res['verification_method'] == 'totp') {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => TotpRegistrationScreen(
              verificationId: res['verification_id'] as String,
              secret: res['totp_secret'] as String,
              uri: res['totp_uri'] as String,
            ),
          ),
        );
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => PhoneVerificationScreen(
              verificationId: res['verification_id'] as String,
              mobileNumber:
                  res['mobile_number'] as String? ?? _mobileCtrl.text.trim(),
              flow: PhoneVerificationFlow.registration,
              deliveryChannel: res['delivery_channel'] as String? ?? 'sms',
              resendAfterSeconds:
                  (res['resend_after_seconds'] as num?)?.toInt() ?? 300,
            ),
          ),
        );
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = AppLocale.pick('خطا در ارتباط با سرور', 'Could not connect to the server.'));
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
        title: Text(AppLocale.pick('ثبت‌نام', 'Create account'), style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 72,
                    height: 72,
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
                    child: const Icon(Icons.person_add_rounded, size: 36, color: Colors.white),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  AppLocale.pick('ایجاد حساب جدید', 'Create your Reyno account'),
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  AppLocale.pick(
                    _registrationUsesTotp
                        ? 'روش تأیید: Google Authenticator.'
                        : 'روش تأیید: پیامک.',
                    _registrationUsesTotp
                        ? 'Verification method: Google Authenticator.'
                        : 'Verification method: SMS text message.',
                  ),
                  style: TextStyle(
                    color: theme.textTheme.bodySmall?.color,
                    fontSize: 13,
                    height: 1.35,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 26),
                TextFormField(
                  controller: _displayNameCtrl,
                  decoration: InputDecoration(
                    labelText: AppLocale.pick('نام نمایشی', 'Display name'),
                    prefixIcon: Icon(Icons.person_outline_rounded, color: primary),
                  ),
                  validator: (v) => (v == null || v.trim().length < 2)
                      ? AppLocale.pick('حداقل ۲ کاراکتر', 'Enter at least 2 characters.')
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _usernameCtrl,
                  decoration: InputDecoration(
                    labelText: AppLocale.pick('آیدی (اختیاری)', 'Username (optional)'),
                    prefixIcon: Icon(Icons.alternate_email_rounded, color: primary),
                    helperText:
                        AppLocale.pick('فقط حروف کوچک، عدد و _ — بعداً هم می‌توانید بسازید', 'Lowercase letters, numbers, and _ only. You can add one later.' ),
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return null;
                    if (t.length < 3 || t.length > 30) return AppLocale.pick('۳ تا ۳۰ کاراکتر', 'Use 3–30 characters.');
                    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(t)) {
                      return AppLocale.pick('فرمت نامعتبر', 'Invalid format.');
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: AppLocale.pick('ایمیل', 'Email'),
                    prefixIcon: Icon(Icons.email_outlined, color: primary),
                  ),
                  validator: (v) {
                    if (v == null || !v.contains('@')) return AppLocale.pick('ایمیل نامعتبر', 'Enter a valid email address.');
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _mobileCtrl,
                  keyboardType: TextInputType.phone,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(
                    labelText: _registrationUsesTotp
                        ? AppLocale.pick('شماره موبایل (برای بازیابی)', 'Mobile number (for recovery)')
                        : AppLocale.pick('شماره موبایل', 'Mobile number'),
                    hintText: '09149141414',
                    hintTextDirection: TextDirection.ltr,
                    prefixIcon: Icon(Icons.phone_outlined, color: primary),
                    helperText: AppLocale.pick('با کد کشور وارد کنید؛ مثال: 09121234567', 'Include the country code, e.g. +1 555 123 4567.'),
                  ),
                  validator: (v) {
                    final compact = (v ?? '').replaceAll(
                      RegExp(r'[\s()\-.]'),
                      '',
                    );
                    if (!RegExp(r'^(?:\+|00)?[0-9]{8,15}$').hasMatch(compact)) {
                      return AppLocale.pick('شماره موبایل نامعتبر', 'Enter a valid mobile number.');
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordCtrl,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: AppLocale.pick('رمز عبور', 'Password'),
                    prefixIcon: Icon(Icons.lock_outline_rounded, color: primary),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) =>
                      (v == null || v.length < 8) ? AppLocale.pick('حداقل ۸ کاراکتر', 'Use at least 8 characters.') : null,
                ),
                const SizedBox(height: 18),
                InkWell(
                  onTap: _showTerms,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: _termsAccepted
                            ? const Color(0xFF4CAF50)
                            : theme.dividerColor.withValues(alpha: 0.5),
                        width: _termsAccepted ? 1.5 : 1.0,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      color: _termsAccepted
                          ? const Color(0xFF4CAF50).withValues(alpha: 0.08)
                          : null,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _termsAccepted
                              ? Icons.check_circle_rounded
                              : Icons.rule_rounded,
                          color: _termsAccepted ? const Color(0xFF4CAF50) : primary,
                          size: 26,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                AppLocale.pick('قوانین و مقررات', 'Terms and conditions'),
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                              ),
                              Text(
                                AppLocale.pick('برای مطالعه و پذیرش لمس کنید (اسکرول تا انتها)', 'Tap to read and accept (scroll to the end)'),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.textTheme.bodySmall?.color,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_termsAccepted)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF4CAF50).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              AppLocale.pick('پذیرفته شد', 'Accepted'),
                              style: TextStyle(
                                color: Color(0xFF2E7D32),
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
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
                            AppLocale.pick('ثبت‌نام و ادامه', 'Sign up and continue'),
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
