import 'package:flutter/material.dart';

import '../../../data/services/api_service.dart';
import '../../../data/services/device_service.dart';

/// Point 6: "Contact support" for people who are stuck on the login or the
/// code screen. It deliberately works while signed out — the only thing the
/// server needs is a phone number to answer on.
///
/// Telegram shows the same entry point in both places, so both the login
/// screen and the verification screen call [showSupportContactSheet].
Future<bool> showSupportContactSheet(
  BuildContext context, {
  String? mobileNumber,
  String? initialTopic,
}) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _SupportContactSheet(
      mobileNumber: mobileNumber,
      initialTopic: initialTopic,
    ),
  );
  return sent ?? false;
}

/// Fallback list used when the server cannot be reached; keeps the sheet
/// usable on a flaky connection instead of showing an empty dropdown.
const List<Map<String, String>> _fallbackTopics = [
  {'id': 'code_not_received', 'title': 'کد تأیید را دریافت نکردم'},
  {'id': 'login_problem', 'title': 'مشکل در ورود به حساب'},
  {'id': 'account_locked', 'title': 'حساب من قفل یا محدود شده'},
  {'id': 'lost_number', 'title': 'به شماره قبلی دسترسی ندارم'},
  {'id': 'bug_report', 'title': 'گزارش اشکال'},
  {'id': 'other', 'title': 'موضوع دیگر'},
];

class _SupportContactSheet extends StatefulWidget {
  const _SupportContactSheet({this.mobileNumber, this.initialTopic});

  final String? mobileNumber;
  final String? initialTopic;

  @override
  State<_SupportContactSheet> createState() => _SupportContactSheetState();
}

class _SupportContactSheetState extends State<_SupportContactSheet> {
  final _formKey = GlobalKey<FormState>();
  final _mobileCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();

  List<Map<String, String>> _topics = _fallbackTopics;
  late String _topic;
  bool _sending = false;
  String? _error;

  String _label(String en, String fa) =>
      Localizations.localeOf(context).languageCode == 'fa' ? fa : en;

  String _topicTitle(Map<String, String> topic) => switch (topic['id']) {
    'code_not_received' => _label('I did not receive a verification code', 'کد تأیید را دریافت نکردم'),
    'login_problem' => _label('Trouble signing in', 'مشکل در ورود به حساب'),
    'account_locked' => _label('My account is locked or restricted', 'حساب من قفل یا محدود شده'),
    'lost_number' => _label('I no longer have my old phone number', 'به شماره قبلی دسترسی ندارم'),
    'bug_report' => _label('Report a bug', 'گزارش اشکال'),
    'abuse' => _label('Report abuse', 'گزارش سوءاستفاده'),
    _ => _label('Other', 'موضوع دیگر'),
  };

  @override
  void initState() {
    super.initState();
    _mobileCtrl.text = widget.mobileNumber ?? '';
    _topic = widget.initialTopic ?? _fallbackTopics.first['id']!;
    _loadTopics();
  }

  @override
  void dispose() {
    _mobileCtrl.dispose();
    _nameCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTopics() async {
    try {
      final response = await ApiService().get('/support/topics');
      final raw = response['topics'] as List? ?? const [];
      final parsed = raw
          .whereType<Map<String, dynamic>>()
          .map((topic) => {
                'id': '${topic['id']}',
                'title': '${topic['title'] ?? topic['id']}',
              })
          .toList();
      if (!mounted || parsed.isEmpty) return;
      setState(() {
        _topics = parsed;
        if (!parsed.any((topic) => topic['id'] == _topic)) {
          _topic = parsed.first['id']!;
        }
      });
    } catch (_) {
      // The fallback list already covers the common cases.
    }
  }

  Future<void> _send() async {
    if (_sending || !_formKey.currentState!.validate()) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final device = await DeviceService.getDeviceInfo();
      await ApiService().post('/support/tickets', {
        'mobile_number': _mobileCtrl.text.trim(),
        'display_name': _nameCtrl.text.trim(),
        'topic': _topic,
        'message': _messageCtrl.text.trim(),
        'platform': device['os'],
        'app_version': device['app_version'],
        'device_info': device,
      });
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = _label('Could not send your support request. Please try again.', 'ارسال پیام به پشتیبانی ممکن نشد. دوباره تلاش کنید.'));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  bool _validPhone(String value) {
    final compact = value.replaceAll(RegExp(r'[\s()\-.]'), '');
    return RegExp(r'^(?:\+|00)?[0-9]{8,15}$').hasMatch(compact);
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + insets),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.support_agent, color: Colors.blue, size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _label('Contact support', 'تماس با پشتیبانی'),
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _label('If you did not receive a sign-in code or cannot sign in, describe the problem here. Support will reply to this phone number.', 'اگر کد ورود را دریافت نمی‌کنید یا نمی‌توانید وارد شوید، مشکل را اینجا بنویسید. پاسخ پشتیبانی به همین شماره اطلاع داده می‌شود.'),
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _mobileCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: _label('Your phone number', 'شماره موبایل شما'),
                  prefixIcon: const Icon(Icons.phone_outlined),
                ),
                validator: (value) =>
                    _validPhone(value ?? '') ? null : _label('Invalid phone number', 'شماره موبایل نامعتبر است'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: _label('Your name (optional)', 'نام شما (اختیاری)'),
                  prefixIcon: const Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _topic,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: _label('Topic', 'موضوع'),
                  prefixIcon: const Icon(Icons.topic_outlined),
                ),
                items: _topics
                    .map((topic) => DropdownMenuItem(
                          value: topic['id'],
                          child: Text(_topicTitle(topic),
                              overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: _sending
                    ? null
                    : (value) => setState(() => _topic = value ?? _topic),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _messageCtrl,
                maxLines: 4,
                maxLength: 2000,
                decoration: InputDecoration(
                  labelText: _label('Describe the problem', 'شرح مشکل'),
                  alignLabelWithHint: true,
                ),
                validator: (value) => (value ?? '').trim().length < 5
                    ? _label('Please add a little more detail.', 'لطفاً مشکل را کمی کامل‌تر بنویسید')
                    : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(_error!,
                    style: const TextStyle(color: Colors.red, fontSize: 13)),
              ],
              const SizedBox(height: 12),
              SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.send_rounded, size: 18),
                  label: Text(_sending ? _label('Sending…', 'در حال ارسال…') : _label('Send to support', 'ارسال به پشتیبانی')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
