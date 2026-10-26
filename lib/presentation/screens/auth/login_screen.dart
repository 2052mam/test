import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/app_locale.dart';
import '../../../data/models/user_model.dart';
import '../../../data/services/account_service.dart';
import '../../../data/services/api_service.dart';
import '../../../data/services/device_service.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/chat/chat_avatar.dart';
import 'phone_verification_screen.dart';
import 'register_screen.dart';
import 'support_contact_sheet.dart';
import 'two_factor_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  /// True when this screen was pushed by "Add account" while another account
  /// is still signed in. Backing out keeps the current account unchanged.
  final bool isAddAccount;

  const LoginScreen({super.key, this.isAddAccount = false});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _mobileCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  bool _legacyMode = false;
  bool _loginPriorityTotp = false;
  String? _error;

  List<SavedAccount> _saved = [];
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _loadSavedAccounts();
    _loadAuthMethods();
  }

  @override
  void dispose() {
    _mobileCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAuthMethods() async {
    try {
      final methods = await ApiService().get('/auth/methods');
      if (!mounted) return;
      final totpPrimary = methods['login_priority'] == 'totp';
      setState(() {
        _loginPriorityTotp = totpPrimary;
        if (totpPrimary) _legacyMode = true;
      });
    } catch (_) {
      // Preserve the existing SMS-first screen if policy lookup is unavailable.
    }
  }

  Future<void> _loadSavedAccounts() async {
    final list = await AccountService.list();
    if (!mounted) return;
    final currentId = ref.read(authNotifierProvider).valueOrNull?.id;
    setState(() => _saved = list.where((account) => account.userId != currentId).toList());
  }

  bool _validPhone(String value) {
    final compact = value.replaceAll(RegExp(r'[\s()\-.]'), '');
    return RegExp(r'^(?:\+|00)?[0-9]{8,15}$').hasMatch(compact);
  }

  Future<void> _submit() async {
    if (_loading || !_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_legacyMode) {
        await _submitLegacy();
      } else {
        await _submitPhone();
      }
    } on ApiException catch (error) {
      if (!mounted) return;
      if (_legacyMode && error.statusCode == 401 && error.message.contains('2FA')) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TwoFactorScreen(
              email: _emailCtrl.text.trim(),
              password: _passwordCtrl.text,
            ),
          ),
        );
      } else if (_legacyMode && error.details['require_phone'] == true) {
        setState(() {
          _legacyMode = false;
          _error = AppLocale.pick(
            'این حساب Google Authenticator ندارد؛ با شماره موبایل و پیامک وارد شوید.',
            'This account has no authenticator enrolled. Sign in with your phone and SMS instead.',
          );
        });
      } else {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted) setState(() => _error = AppLocale.pick('خطا در ارتباط با سرور', 'Could not connect to the server.'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submitPhone() async {
    final mobile = _mobileCtrl.text.trim();
    final response = await ApiService().post('/auth/request-phone-code', {
      'mobile_number': mobile,
    });
    if (!mounted) return;
    final verificationId = response['verification_id'] as String?;
    final needsRegistration =
        response['registration_required'] == true || verificationId == null;
    if (needsRegistration) {
      await _openRegistration(mobile);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhoneVerificationScreen(
          verificationId: verificationId,
          mobileNumber: response['mobile_number'] as String? ?? mobile,
          flow: PhoneVerificationFlow.login,
          deliveryChannel: response['delivery_channel'] as String? ?? 'sms',
          resendAfterSeconds:
              (response['resend_after_seconds'] as num?)?.toInt() ?? 300,
        ),
      ),
    );
  }

  Future<void> _openRegistration(String mobileNumber) async {
    if (!mounted) return;
    setState(() => _error = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocale.pick('این شماره ثبت‌نام نشده است؛ ابتدا ثبت‌نام کنید.', 'This number is not registered. Please sign up first.')),
      ),
    );
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RegisterScreen(initialMobileNumber: mobileNumber),
      ),
    );
  }

  Future<void> _contactSupport() async {
    final sent = await showSupportContactSheet(
      context,
      mobileNumber: _mobileCtrl.text.trim().isEmpty
          ? null
          : _mobileCtrl.text.trim(),
      initialTopic: 'login_problem',
    );
    if (sent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocale.pick('پیام شما برای پشتیبانی ثبت شد.', 'Your message was sent to support.')),
        ),
      );
    }
  }

  Future<void> _submitLegacy() async {
    final response = await ApiService().post('/auth/login', {
      'email': _emailCtrl.text.trim(),
      'password': _passwordCtrl.text,
      'device_info': await DeviceService.getDeviceInfo(),
    });
    if (!mounted) return;
    await _saveSession(response);
  }

  Future<void> _saveSession(Map<String, dynamic> response) async {
    final user = UserModel.fromJson(response['user'] as Map<String, dynamic>);
    await ref.read(authNotifierProvider.notifier).setLoggedIn(
          user,
          response['access_token'] as String,
          response['refresh_token'] as String? ?? '',
        );
  }

  Future<void> _useSavedAccount(SavedAccount account) async {
    if (_switching) return;
    setState(() {
      _switching = true;
      _error = null;
    });
    try {
      await ref.read(authNotifierProvider.notifier).switchAccount(account);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _switching = false;
        _error = AppLocale.pick('ورود با این حساب ممکن نشد. شماره موبایل یا رمز عبور را وارد کنید.', 'Could not sign in to this account. Enter the phone number or password.');
      });
      await AccountService.remove(account.userId);
      await _loadSavedAccounts();
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPop = widget.isAddAccount && Navigator.of(context).canPop();
    final phoneMode = !_legacyMode;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;

    return Scaffold(
      appBar: widget.isAddAccount
          ? AppBar(
              title: Text(AppLocale.pick('افزودن حساب', 'Add account')),
              leading: canPop
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: AppLocale.pick('بازگشت به حساب فعلی', 'Return to current account'),
                      onPressed: () => Navigator.of(context).pop(),
                    )
                  : null,
            )
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 12),
                  Center(
                    child: Image.asset(
                      isDark
                          ? 'assets/icons/reyno_logo_dark.png'
                          : 'assets/icons/reyno_logo.png',
                      width: 228,
                      height: 76,
                      fit: BoxFit.contain,
                      semanticLabel: 'Reyno',
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    widget.isAddAccount ? AppLocale.pick('افزودن حساب جدید', 'Add another account') : AppLocale.pick('ورود به Reyno', 'Sign in to Reyno'),
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    phoneMode
                        ? AppLocale.pick('شماره موبایل خود را وارد کنید؛ اگر ثبت‌نام نکرده‌اید به صفحه ثبت‌نام می‌روید', 'Enter your mobile number. If you are not registered, you can sign up next.')
                        : AppLocale.pick(_loginPriorityTotp ? 'ورود با ایمیل، رمز عبور و کد Google Authenticator' : 'ورود ایمیلی فقط برای حساب‌های قدیمیِ بدون شماره موبایل است', _loginPriorityTotp ? 'Primary sign-in: email, password, and Google Authenticator code.' : 'Email sign-in is available only for legacy accounts without a mobile number.'),
                    style: TextStyle(
                      color: theme.textTheme.bodySmall?.color,
                      fontSize: 13.5,
                      height: 1.35,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  if (_saved.isNotEmpty) ...[
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        AppLocale.pick('ادامه با حساب‌های ذخیره‌شده', 'Continue with a saved account'),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                          color: primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._saved.map(
                      (account) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF17212B) : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.dividerColor.withValues(alpha: 0.35),
                          ),
                        ),
                        child: ListTile(
                          leading: ChatAvatar(
                            title: account.displayName,
                            url: account.avatarUrl,
                            token: account.accessToken,
                            radius: 20,
                          ),
                          title: Text(account.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(account.handle),
                          trailing: _switching
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.arrow_forward_ios_rounded, size: 14),
                          onTap: _switching ? null : () => _useSavedAccount(account),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(child: Divider(color: theme.dividerColor.withValues(alpha: 0.3))),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            AppLocale.pick('یا ورود با شماره دیگر', 'Or sign in with another number'),
                            style: TextStyle(fontSize: 12, color: theme.textTheme.bodySmall?.color),
                          ),
                        ),
                        Expanded(child: Divider(color: theme.dividerColor.withValues(alpha: 0.3))),
                      ],
                    ),
                    const SizedBox(height: 18),
                  ],
                  if (phoneMode) ...[
                    TextFormField(
                      controller: _mobileCtrl,
                      keyboardType: TextInputType.phone,
                      autofocus: !widget.isAddAccount && _saved.isEmpty,
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(
                        labelText: AppLocale.pick('شماره موبایل', 'Mobile number'),
                        hintText: '+989121234567',
                        hintTextDirection: TextDirection.ltr,
                        prefixIcon: Icon(Icons.phone_iphone_rounded, color: primary),
                        helperText: AppLocale.pick('شماره همراه با کد کشور (مثال: +989121234567 یا 09121234567)', 'Include the country code (e.g. +989121234567).'),
                      ),
                      validator: (value) => _validPhone(value ?? '')
                          ? null
                          : AppLocale.pick('شماره موبایل معتبر نیست', 'Enter a valid mobile number.'),
                    ),
                  ] else ...[
                    TextFormField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: AppLocale.pick('ایمیل', 'Email'),
                        prefixIcon: Icon(Icons.email_outlined, color: primary),
                      ),
                      validator: (value) => (value == null || !value.contains('@'))
                          ? AppLocale.pick('ایمیل نامعتبر است', 'Enter a valid email address.')
                          : null,
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
                      validator: (value) => (value == null || value.length < 6)
                          ? AppLocale.pick('رمز عبور حداقل ۶ کاراکتر است', 'Password must be at least 6 characters.')
                          : null,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline_rounded, color: Colors.red, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(color: Colors.red, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primary,
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
                              phoneMode ? AppLocale.pick('ادامه', 'Continue') : AppLocale.pick('ورود', 'Sign in'),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () => setState(() {
                          _legacyMode = !_legacyMode;
                          _error = null;
                        }),
                        child: Text(
                          phoneMode ? AppLocale.pick('ورود با ایمیل و رمز', 'Sign in with email and password') : AppLocale.pick('ورود با شماره موبایل', 'Sign in with mobile number'),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      TextButton.icon(
                        key: const ValueKey('login-contact-support'),
                        icon: const Icon(Icons.support_agent_rounded, size: 18),
                        label: Text(AppLocale.pick('پشتیبانی', 'Support'), style: const TextStyle(fontSize: 13)),
                        onPressed: _contactSupport,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (!widget.isAddAccount)
                    Center(
                      child: TextButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const RegisterScreen(),
                            ),
                          );
                        },
                        child: Text(
                          AppLocale.pick('حساب ندارید؟ ثبت‌نام کنید', 'New to Reyno? Sign up'),
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
