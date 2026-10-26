import 'package:flutter/material.dart';
import '../../../data/models/message_model.dart';
import '../../../data/services/api_service.dart';

class ScheduledMessagesSheet extends StatefulWidget {
  final String chatId;
  final ApiService api;

  const ScheduledMessagesSheet({
    super.key,
    required this.chatId,
    required this.api,
  });

  @override
  State<ScheduledMessagesSheet> createState() => _ScheduledMessagesSheetState();
}

class _ScheduledMessagesSheetState extends State<ScheduledMessagesSheet> {
  bool _loading = true;
  String? _error;
  List<MessageModel> _messages = [];

  String _t(String en, String fa) =>
      Localizations.localeOf(context).languageCode == 'fa' ? fa : en;

  @override
  void initState() {
    super.initState();
    _loadScheduled();
  }

  Future<void> _loadScheduled() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.api.get('/messages/chat/${widget.chatId}/scheduled');
      final list = (res['messages'] as List? ?? [])
          .map((e) => MessageModel.fromJson(e as Map<String, dynamic>))
          .toList();
      if (mounted) {
        setState(() {
          _messages = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _sendNow(String messageId) async {
    try {
      await widget.api.post('/messages/$messageId/scheduled/send-now', {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t('Message sent immediately.', 'پیام به طور فوری ارسال شد'))),
        );
        _loadScheduled();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t('Error: $e', 'خطا: $e'))),
        );
      }
    }
  }

  Future<void> _cancelScheduled(String messageId) async {
    try {
      await widget.api.post('/messages/$messageId/scheduled', {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t('Scheduled message cancelled.', 'ارسال زمان‌بندی‌شده لغو شد'))),
        );
        _loadScheduled();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t('Error: $e', 'خطا: $e'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  const Icon(Icons.schedule, color: Colors.blue),
                  const SizedBox(width: 8),
                  Text(
                    _t('Scheduled messages', 'پیام‌های زمان‌بندی‌شده'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _loadScheduled,
                  ),
                ],
              ),
              const Divider(),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
                        : _messages.isEmpty
                            ? Center(
                                child: Text(
                                  _t('There are no scheduled messages in this chat.', 'هیچ پیام زمان‌بندی‌شده‌ای در این چت نیست'),
                                  style: const TextStyle(color: Colors.grey),
                                ),
                              )
                            : ListView.builder(
                                controller: scrollController,
                                itemCount: _messages.length,
                                itemBuilder: (context, index) {
                                  final msg = _messages[index];
                                  final scheduledTimeStr = msg.scheduledAt != null
                                      ? '${msg.scheduledAt!.year}/${msg.scheduledAt!.month}/${msg.scheduledAt!.day} ${_t('at', 'ساعت')} ${msg.scheduledAt!.hour.toString().padLeft(2, '0')}:${msg.scheduledAt!.minute.toString().padLeft(2, '0')}'
                                      : _t('Scheduled', 'زمان‌بندی‌شده');
                                  return Card(
                                    margin: const EdgeInsets.symmetric(vertical: 6),
                                    child: ListTile(
                                      title: Text(
                                        msg.content?.isNotEmpty == true
                                            ? msg.content!
                                            : _t('[Media]', '[رسانه]'),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        _t('Send time: $scheduledTimeStr', 'زمان ارسال: $scheduledTimeStr'),
                                        style: TextStyle(color: Colors.blue[700], fontSize: 12),
                                      ),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.send_rounded, color: Colors.green),
                                            tooltip: _t('Send now', 'ارسال فوری'),
                                            onPressed: () => _sendNow(msg.id),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                                            tooltip: _t('Cancel scheduled message', 'لغو زمان‌بندی'),
                                            onPressed: () => _cancelScheduled(msg.id),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
              ),
            ],
          ),
        );
      },
    );
  }
}
