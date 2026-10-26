import 'package:flutter/material.dart';
import '../../../data/services/api_service.dart';

class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});
  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final _api = ApiService();
  List<dynamic> _reports = [];
  bool _loading = true;
  String _filter = 'pending';
  String? _error;

  String _t(String en, String fa) =>
      Localizations.localeOf(context).languageCode == 'fa' ? fa : en;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() {
      if (_tabs.indexIsChanging) return;
      final vals = ['pending', 'resolved', 'all'];
      setState(() => _filter = vals[_tabs.index]);
      _load();
    });
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _api.get('/reports/', query: {'status': _filter});
      if (!mounted) return;
      setState(() { _reports = res['reports'] as List? ?? []; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _handleUserReport(String reportId, String action) async {
    String? reason;
    if (action == 'limit' || action == 'deactivate') {
      reason = await showDialog<String>(context: context, builder: (ctx) {
        final c = TextEditingController(text: _t('Policy violation', 'نقض قوانین'));
        return AlertDialog(
          title: Text(action == 'limit' ? _t('Restrict user (cannot start new chats)', 'محدود کردن کاربر (Telegram: cannot start new chats)') : _t('Deactivate account', 'غیرفعال‌سازی حساب')),
          content: TextField(controller: c, decoration: InputDecoration(hintText: _t('Reason', 'دلیل'), border: const OutlineInputBorder())),
          actions: [TextButton(onPressed: ()=>Navigator.pop(ctx), child: Text(_t('Cancel', 'لغو'))), ElevatedButton(onPressed: ()=>Navigator.pop(ctx, c.text), child: Text(_t('Confirm', 'تایید')))],
        );
      });
      if (reason == null) return;
    }
    try {
      await _api.post('/reports/$reportId/handle-user', {'action': action, 'reason': reason, 'duration_days': action=='limit'? 7: null});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(action=='dismiss'? _t('Report dismissed.', 'گزارش رد شد') : action=='limit'? _t('User restricted; existing chats remain, new chats are blocked.', 'کاربر محدود شد (چت‌های قبلی باقی، چت جدید مسدود)') : _t('Account deactivated.', 'حساب غیرفعال شد'))));
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _handleChatReport(String reportId, String action) async {
    final reasonCtrl = TextEditingController();
    final reason = action=='dismiss' ? null : await showDialog<String>(context: context, builder: (ctx) => AlertDialog(title: Text(action=='suspend'? _t('Suspend', 'تعلیق'): action=='close'? _t('Close', 'بستن'): _t('Delete', 'حذف')), content: TextField(controller: reasonCtrl, decoration: InputDecoration(hintText: _t('Reason shown to the owner', 'دلیل نمایش به مالک'), border: const OutlineInputBorder()), autofocus: true), actions: [TextButton(onPressed: ()=>Navigator.pop(ctx), child: Text(_t('Cancel', 'لغو'))), ElevatedButton(onPressed: ()=>Navigator.pop(ctx, reasonCtrl.text), child: Text(_t('Confirm', 'تایید')))]));
    if (action!='dismiss' && reason==null) return;
    try {
      await _api.post('/reports/$reportId/handle-chat', {'action': action, 'reason': reason});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(action=='dismiss'? _t('Dismissed.', 'رد شد') : action=='suspend'? _t('Group/channel suspended.', 'گروه/کانال تعلیق شد') : action=='close'? _t('Closed.', 'بسته شد') : _t('Deleted.', 'حذف شد'))));
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_t('Reports — Admin panel', 'گزارش‌ها - پنل مدیریت')),
        bottom: TabBar(controller: _tabs, tabs: [Tab(text: _t('Pending', 'در انتظار')), Tab(text: _t('Resolved', 'حل‌شده')), Tab(text: _t('All', 'همه'))], onTap: (i){ final vals=['pending','resolved','all']; setState(()=>_filter=vals[i]); _load(); }),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator()) : _error!=null ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red))) : _reports.isEmpty ? Center(child: Text(_t('No reports found.', 'گزارشی یافت نشد'))) : RefreshIndicator(
        onRefresh: _load,
        child: ListView.builder(
          itemCount: _reports.length,
          padding: const EdgeInsets.all(12),
          itemBuilder: (_, i){
            final r = _reports[i] as Map<String,dynamic>;
            final type = r['target_type'] as String? ?? '';
            final status = r['status'] as String? ?? '';
            final reason = r['reason'] as String? ?? '';
            final desc = r['description'] as String? ?? '';
            final reporter = r['reporter'] as Map<String,dynamic>?;
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: type=='user'? Colors.orange.withValues(alpha:0.12): Colors.purple.withValues(alpha:0.12), borderRadius: BorderRadius.circular(8)), child: Text(type=='user'? _t('User', 'کاربر'): type=='chat'? _t('Group/channel', 'گروه/کانال'): _t('Message', 'پیام'), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: type=='user'? Colors.orange: Colors.purple))),
                    const SizedBox(width: 8),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: status=='pending'? Colors.amber.withValues(alpha:0.15): Colors.green.withValues(alpha:0.15), borderRadius: BorderRadius.circular(8)), child: Text(status=='pending'? _t('Pending', 'در انتظار'): status=='resolved'? _t('Resolved', 'حل‌شده'): status, style: TextStyle(fontSize: 11, color: status=='pending'? Colors.amber: Colors.green))),
                    const Spacer(),
                    Text((r['created_at'] as String? ?? '').split('T').first, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ]),
                  const SizedBox(height: 8),
                  Text('${_t('Reason', 'دلیل')}: $reason', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  if (desc.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(desc, style: const TextStyle(fontSize: 12, color: Colors.grey))),
                  const SizedBox(height: 8),
                  if (reporter != null) Text('${_t('Reported by', 'گزارشگر')}: ${reporter['display_name'] ?? reporter['username'] ?? ''} (@${reporter['username'] ?? ''})', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  if ((r['target_user'] as Map?) != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${_t('Target user', 'کاربر هدف')}: ${(r['target_user'] as Map)['display_name']} @${(r['target_user'] as Map)['username']}', style: const TextStyle(fontSize: 12, color: Colors.red))),
                  if ((r['target_chat'] as Map?) != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${_t('Target chat', 'چت هدف')}: ${(r['target_chat'] as Map)['title']} (${(r['target_chat'] as Map)['chat_type']})', style: const TextStyle(fontSize: 12, color: Colors.purple))),
                  const Divider(height: 16),
                  if (status=='pending') Wrap(spacing: 8, children: type=='user' ? [
                    ElevatedButton.icon(icon: const Icon(Icons.block, size: 16), label: Text(_t('Restrict (block new chats)', 'محدود (چت جدید مسدود)'), style: const TextStyle(fontSize: 11)), style: ElevatedButton.styleFrom(backgroundColor: Colors.orange), onPressed: ()=>_handleUserReport(r['id'] as String, 'limit')),
                    ElevatedButton.icon(icon: const Icon(Icons.person_off, size: 16), label: Text(_t('Deactivate', 'غیرفعال'), style: const TextStyle(fontSize: 11)), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), onPressed: ()=>_handleUserReport(r['id'] as String, 'deactivate')),
                    OutlinedButton(onPressed: ()=>_handleUserReport(r['id'] as String, 'dismiss'), child: Text(_t('Dismiss', 'رد'), style: const TextStyle(fontSize: 11))),
                  ] : type=='chat' ? [
                    ElevatedButton.icon(icon: const Icon(Icons.pause_circle_outline, size: 16), label: Text(_t('Suspend', 'تعلیق'), style: const TextStyle(fontSize: 11)), style: ElevatedButton.styleFrom(backgroundColor: Colors.orange), onPressed: ()=>_handleChatReport(r['id'] as String, 'suspend')),
                    ElevatedButton.icon(icon: const Icon(Icons.lock_outline, size: 16), label: Text(_t('Close', 'بستن'), style: const TextStyle(fontSize: 11)), onPressed: ()=>_handleChatReport(r['id'] as String, 'close')),
                    ElevatedButton.icon(icon: const Icon(Icons.delete_forever, size: 16), label: Text(_t('Delete', 'حذف'), style: const TextStyle(fontSize: 11)), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), onPressed: ()=>_handleChatReport(r['id'] as String, 'delete')),
                    OutlinedButton(onPressed: ()=>_handleChatReport(r['id'] as String, 'dismiss'), child: Text(_t('Dismiss', 'رد'))),
                  ] : [
                    OutlinedButton(onPressed: ()=>_handleUserReport(r['id'] as String, 'dismiss'), child: Text(_t('Dismiss', 'رد'))),
                  ]) else Text('${_t('Action', 'اقدام')}: ${r['resolution'] ?? ''} ${r['resolution_reason'] ?? ''}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose(){ _tabs.dispose(); super.dispose(); }
}
