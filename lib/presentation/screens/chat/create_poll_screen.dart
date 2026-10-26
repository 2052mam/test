import 'package:flutter/material.dart';

import '../../../data/services/api_service.dart';

/// Telegram's "Create Poll" sheet: a question, 2–10 options, and the
/// quiz/anonymous/multiple-answer switches.
class CreatePollScreen extends StatefulWidget {
  const CreatePollScreen({
    super.key,
    required this.chatId,
    required this.api,
    this.replyToId,
    this.quiz = false,
  });

  final String chatId;
  final ApiService api;
  final String? replyToId;

  /// Opens straight in quiz mode (Telegram's "Quiz Mode" toggle preselected).
  final bool quiz;

  static const int maxOptions = 10;
  static const int minOptions = 2;

  @override
  State<CreatePollScreen> createState() => _CreatePollScreenState();
}

class _CreatePollScreenState extends State<CreatePollScreen> {
  final _questionCtrl = TextEditingController();
  final _explanationCtrl = TextEditingController();
  final List<TextEditingController> _optionCtrls = [
    TextEditingController(),
    TextEditingController(),
  ];

  late bool _quizMode = widget.quiz;
  bool _anonymous = true;
  bool _multiple = false;
  int? _correctIndex;
  bool _sending = false;
  String? _error;

  String _t(String en, String fa) =>
      Localizations.localeOf(context).languageCode == 'fa' ? fa : en;

  @override
  void dispose() {
    _questionCtrl.dispose();
    _explanationCtrl.dispose();
    for (final controller in _optionCtrls) {
      controller.dispose();
    }
    super.dispose();
  }

  List<String> get _filledOptions => _optionCtrls
      .map((controller) => controller.text.trim())
      .where((text) => text.isNotEmpty)
      .toList();

  bool get _canSend =>
      _questionCtrl.text.trim().isNotEmpty &&
      _filledOptions.length >= CreatePollScreen.minOptions &&
      (!_quizMode || _correctIndex != null);

  void _addOption() {
    if (_optionCtrls.length >= CreatePollScreen.maxOptions) return;
    setState(() => _optionCtrls.add(TextEditingController()));
  }

  void _removeOption(int index) {
    if (_optionCtrls.length <= CreatePollScreen.minOptions) return;
    setState(() {
      _optionCtrls.removeAt(index).dispose();
      if (_correctIndex != null) {
        if (_correctIndex == index) {
          _correctIndex = null;
        } else if (_correctIndex! > index) {
          _correctIndex = _correctIndex! - 1;
        }
      }
    });
  }

  Future<void> _submit() async {
    if (_sending || !_canSend) return;
    // The correct index refers to the *filled* options actually sent.
    final texts = <String>[];
    int? correct;
    for (var i = 0; i < _optionCtrls.length; i++) {
      final text = _optionCtrls[i].text.trim();
      if (text.isEmpty) continue;
      if (_quizMode && _correctIndex == i) correct = texts.length;
      texts.add(text);
    }
    if (_quizMode && correct == null) {
      setState(() => _error = _t('Select the correct answer.', 'گزینه صحیح را انتخاب کنید'));
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final response = await widget.api.post('/polls/', {
        'chat_id': widget.chatId,
        'question': _questionCtrl.text.trim(),
        'options': [for (final text in texts) {'text': text}],
        'poll_type': _quizMode ? 'quiz' : 'regular',
        'is_anonymous': _anonymous,
        'allows_multiple_answers': _quizMode ? false : _multiple,
        if (_quizMode) 'correct_option_index': correct,
        if (_quizMode && _explanationCtrl.text.trim().isNotEmpty)
          'explanation': _explanationCtrl.text.trim(),
        if (widget.replyToId != null) 'reply_to_id': widget.replyToId,
      });
      if (!mounted) return;
      Navigator.of(context).pop(response);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _sending = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = _t('Could not send the poll.', 'ارسال نظرسنجی ناموفق بود');
          _sending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_quizMode ? _t('Create quiz', 'ساخت آزمون') : _t('Create poll', 'ساخت نظرسنجی')),
        actions: [
          TextButton(
            key: const ValueKey('send-poll'),
            onPressed: _canSend && !_sending ? _submit : null,
            child: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_t('Send', 'ارسال')),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              key: const ValueKey('poll-question'),
              controller: _questionCtrl,
              maxLength: 300,
              maxLines: 3,
              minLines: 1,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: _t('Question', 'سؤال'),
                hintText: _t('Write your question', 'سؤال خود را بنویسید'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(_t('Options', 'گزینه‌ها'), style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (var i = 0; i < _optionCtrls.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    if (_quizMode)
                      Radio<int>(
                        key: ValueKey('poll-correct-$i'),
                        value: i,
                        groupValue: _correctIndex,
                        onChanged: (value) => setState(() => _correctIndex = value),
                      ),
                    Expanded(
                      child: TextField(
                        key: ValueKey('poll-option-field-$i'),
                        controller: _optionCtrls[i],
                        maxLength: 100,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: '${_t('Option', 'گزینه')} ${i + 1}',
                          counterText: '',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    if (_optionCtrls.length > CreatePollScreen.minOptions)
                      IconButton(
                        tooltip: _t('Remove option', 'حذف گزینه'),
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => _removeOption(i),
                      ),
                  ],
                ),
              ),
            if (_optionCtrls.length < CreatePollScreen.maxOptions)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('add-poll-option'),
                  onPressed: _addOption,
                  icon: const Icon(Icons.add),
                  label: Text(_t('Add option', 'افزودن گزینه')),
                ),
              ),
            const Divider(height: 24),
            SwitchListTile(
              key: const ValueKey('poll-anonymous'),
              value: _anonymous,
              onChanged: (value) => setState(() => _anonymous = value),
              title: Text(_t('Anonymous voting', 'رأی‌گیری ناشناس')),
              subtitle: Text(_t('Voter names will not be shown.', 'نام رأی‌دهندگان نمایش داده نمی‌شود')),
            ),
            SwitchListTile(
              key: const ValueKey('poll-quiz'),
              value: _quizMode,
              onChanged: (value) => setState(() {
                _quizMode = value;
                if (value) _multiple = false;
                if (!value) _correctIndex = null;
              }),
              title: Text(_t('Quiz mode', 'حالت آزمون')),
              subtitle: Text(_t('One correct answer; votes cannot be changed.', 'یک گزینه صحیح دارد و پاسخ قابل تغییر نیست')),
            ),
            if (!_quizMode)
              SwitchListTile(
                key: const ValueKey('poll-multiple'),
                value: _multiple,
                onChanged: (value) => setState(() => _multiple = value),
                title: Text(_t('Multiple answers', 'چند گزینه‌ای')),
                subtitle: Text(_t('People can select more than one option.', 'کاربر می‌تواند چند گزینه را انتخاب کند')),
              ),
            if (_quizMode)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextField(
                  key: const ValueKey('poll-explanation'),
                  controller: _explanationCtrl,
                  maxLength: 200,
                  decoration: InputDecoration(
                    labelText: _t('Answer explanation (optional)', 'توضیح پاسخ (اختیاری)'),
                    helperText: _t('Shown after answering.', 'بعد از پاسخ دادن نمایش داده می‌شود'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }
}
