import 'package:flutter/material.dart';

import '../../../core/utils/app_locale.dart';
import '../../../core/utils/security_message_localizer.dart';
import '../../../data/services/api_service.dart';

/// Point 4: device and session management with a Telegram-like "primary"
/// device.
///
/// Rules enforced here (and again on the server, which is authoritative):
///  * The first device that ever signed in is the primary one.
///  * No other device may remove it — only the primary device itself can.
///  * "End all other sessions" never touches the primary device.
///  * Two-step verification and the archive lock are primary-device-only; the
///    banner explains that when the current device is not the primary one.
class DeviceManagementScreen extends StatefulWidget {
  const DeviceManagementScreen({super.key});

  @override
  State<DeviceManagementScreen> createState() => _DeviceManagementScreenState();
}

class _DeviceManagementScreenState extends State<DeviceManagementScreen> {
  final _api = ApiService();

  String _t(String en, String fa) => AppLocale.pick(fa, en);

  List<Map<String, dynamic>> _devices = const [];
  List<Map<String, dynamic>> _alerts = const [];
  String? _currentDeviceId;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _onPrimaryDevice => _devices.any(
      (device) => device['is_current'] == true && device['is_primary'] == true);

  bool get _hasPrimary => _devices.any((device) => device['is_primary'] == true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<Map<String, dynamic>> _mapList(dynamic raw) => (raw as List? ?? const [])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final devices = await _api.get('/devices/');
      // The security feed replaced the old saved-message notifications.
      Map<String, dynamic> alerts = const {};
      try {
        alerts = await _api.get('/security/alerts', query: {'limit': '5'});
      } catch (_) {
        // Non-fatal: the device list is still useful on its own.
      }
      if (!mounted) return;
      setState(() {
        _devices = _mapList(devices['devices']);
        _currentDeviceId = devices['current_device_id'] as String?;
        _alerts = _mapList(alerts['alerts']);
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_t('Cancel', 'لغو')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return result == true;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on ApiException catch (error) {
      _toast(error.message);
      // A rejected primary-device action means our copy of the list is stale.
      if (error.code == 'cannot_terminate_primary' ||
          error.code == 'primary_device_required') {
        await _load();
      }
    } catch (error) {
      _toast('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _terminate(Map<String, dynamic> device) async {
    final primary = device['is_primary'] == true;
    final ok = await _confirm(
      primary ? _t('Remove primary device', 'حذف دستگاه اصلی') : _t('End session', 'پایان نشست'),
      primary
          ? _t('This is your account’s primary device. Removing it makes the next active device primary. Continue?', 'این دستگاه اصلی حساب شماست. با حذف آن، دستگاه فعال بعدی به دستگاه اصلی تبدیل می‌شود. ادامه می‌دهید؟')
          : _t('Sign this device out of your account?', 'این دستگاه از حساب خارج شود؟'),
      primary ? _t('Remove primary device', 'حذف دستگاه اصلی') : _t('Confirm', 'تأیید'),
    );
    if (!ok) return;
    await _run(() async {
      await _api.post('/devices/${device['id']}/terminate', {});
      if (!mounted) return;
      setState(() => _devices =
          _devices.where((item) => item['id'] != device['id']).toList());
      _toast(_t('Session ended and device signed out.', 'نشست پایان یافت و دستگاه خارج شد'));
      await _load();
    });
  }

  Future<void> _terminateOthers() async {
    final ok = await _confirm(
      _t('End all other sessions', 'پایان همه نشست‌های دیگر'),
      _t('Sign out every device except this one? Your primary device will not be removed.', 'همه دستگاه‌ها به‌جز دستگاه فعلی خارج شوند؟ دستگاه اصلی حساب حذف نمی‌شود.'),
      _t('End all', 'پایان همه'),
    );
    if (!ok) return;
    await _run(() async {
      final response = await _api.post('/devices/terminate-others', {});
      final count = (response['terminated'] as num?)?.toInt() ?? 0;
      _toast(count > 0
          ? _t('$count other session(s) ended', '$count نشست دیگر پایان یافت')
          : _t('There are no other sessions to end.', 'نشست دیگری برای پایان دادن وجود ندارد'));
      await _load();
    });
  }

  Future<void> _makePrimary(Map<String, dynamic> device) async {
    final ok = await _confirm(
      _t('Transfer primary device', 'انتقال دستگاه اصلی'),
      _t('Make “${device['device_name'] ?? 'Unknown'}” the primary device? After the transfer, security settings can only be changed from that device.', 'دستگاه «${device['device_name'] ?? 'ناشناس'}» به دستگاه اصلی حساب تبدیل شود؟ پس از این، تنظیمات امنیتی فقط از همان دستگاه قابل تغییر است.'),
      _t('Transfer', 'انتقال'),
    );
    if (!ok) return;
    await _run(() async {
      await _api.post('/devices/primary/transfer', {'device_id': device['id']});
      _toast(_t('Primary device changed.', 'دستگاه اصلی تغییر کرد'));
      await _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_t('Devices and sessions', 'دستگاه‌ها و نشست‌ها')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _load,
                        child: Text(_t('Try again', 'تلاش مجدد')),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      _primaryBanner(),
                      if (_alerts.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(_t('Recent security alerts', 'هشدارهای امنیتی اخیر'),
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 6),
                        ..._alerts.map(_alertCard),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text(_t('All active sessions', 'همه نشست‌های فعال'),
                              style: Theme.of(context).textTheme.titleMedium),
                          const Spacer(),
                          if (_devices.length > 1)
                            TextButton.icon(
                              icon: const Icon(Icons.power_settings_new,
                                  size: 18, color: Colors.red),
                              label: Text(_t('End other sessions', 'پایان بقیه نشست‌ها'),
                                  style: const TextStyle(color: Colors.red, fontSize: 12)),
                              onPressed: _busy ? null : _terminateOthers,
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ..._devices.map(_deviceCard),
                      if (_devices.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(child: Text(_t('No devices found', 'دستگاهی یافت نشد')),),
                        ),
                      const SizedBox(height: 16),
                      _explainer(),
                    ],
                  ),
                ),
    );
  }

  Widget _primaryBanner() {
    final onPrimary = _onPrimaryDevice;
    final colour = onPrimary ? Colors.green : Colors.blueGrey;
    return Card(
      color: colour.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(onPrimary ? Icons.verified_user : Icons.shield_outlined,
                color: colour),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    onPrimary
                        ? _t('This is your account’s primary device.', 'این دستگاه، دستگاه اصلی حساب است')
                        : _hasPrimary
                            ? _t('This is not the primary device.', 'این دستگاه، دستگاه اصلی نیست')
                            : _t('No primary device has been set yet.', 'هنوز دستگاه اصلی ثبت نشده است'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    onPrimary
                        ? _t('Two-step verification and the archive chat lock can only be changed from this device.', 'تأیید دو مرحله‌ای و قفل چت‌های بایگانی فقط از همین دستگاه قابل تغییر است.')
                        : _hasPrimary
                            ? _t('You cannot remove the primary device here; security settings are available only on that device.', 'دستگاه اصلی را نمی‌توانید از اینجا حذف کنید و تنظیمات امنیتی فقط روی آن دستگاه در دسترس است.')
                            : _t('The first device to sign in becomes the primary device.', 'اولین دستگاهی که وارد شود، دستگاه اصلی حساب می‌شود.'),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            Text('${_devices.length}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _alertCard(Map<String, dynamic> alert) {
    final critical = alert['severity'] == 'critical';
    return Card(
      color: (critical ? Colors.red : Colors.amber).withValues(alpha: 0.08),
      child: ListTile(
        dense: true,
        leading: Icon(
          critical ? Icons.gpp_maybe : Icons.warning_amber_rounded,
          color: critical ? Colors.red : Colors.orange,
        ),
        title: Text(SecurityMessageLocalizer.localize('${alert['title'] ?? 'رویداد امنیتی'}', isFa: AppLocale.isFa),
            style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          [alert['device_name'], alert['ip_address'], alert['created_at']]
              .where((part) => part != null && '$part'.isNotEmpty)
              .join(' • '),
          style: const TextStyle(fontSize: 11),
        ),
      ),
    );
  }

  Widget _deviceCard(Map<String, dynamic> device) {
    final isCurrent = device['is_current'] == true;
    final isPrimary = device['is_primary'] == true;
    // The server tells us whether this row may be removed from *this* device.
    final canTerminate = device['can_terminate'] == true;
    final lastActive = device['last_active_at'] ?? device['last_active'];

    return Card(
      color: isCurrent ? Colors.blue.withValues(alpha: 0.06) : null,
      child: ListTile(
        isThreeLine: true,
        leading: Icon(
          device['device_type'] == 'desktop'
              ? Icons.computer
              : Icons.phone_android,
          color: isCurrent ? Colors.blue : Colors.grey,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '${device['device_name'] ?? device['device_model'] ?? _t('Unknown', 'ناشناس')}',
                style: TextStyle(
                    fontWeight:
                        isCurrent ? FontWeight.w600 : FontWeight.normal),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isPrimary) _chip(_t('Primary', 'اصلی'), Colors.indigo),
            if (isCurrent) _chip(_t('Current', 'فعلی'), Colors.green),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'IP: ${device['ip_address'] ?? '-'} • '
              '${device['device_model'] ?? ''} ${device['os'] ?? ''}'
              '${device['app_version'] != null ? ' - ${device['app_version']}' : ''}',
              style: const TextStyle(fontSize: 11),
            ),
            if (lastActive != null)
              Text(_t('Last active: $lastActive', 'آخرین فعالیت: $lastActive'),
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            if (isPrimary && !isCurrent)
              Text(
                _t('The primary device can only be removed from that device.', 'دستگاه اصلی فقط از روی خودش قابل حذف است.'),
                style: const TextStyle(fontSize: 11, color: Colors.indigo),
              ),
          ],
        ),
        trailing: _trailing(device, isCurrent, isPrimary, canTerminate),
      ),
    );
  }

  Widget? _trailing(
    Map<String, dynamic> device,
    bool isCurrent,
    bool isPrimary,
    bool canTerminate,
  ) {
    if (isCurrent && !isPrimary) {
      // Offer to take ownership only from the device the user is holding.
      return IconButton(
        tooltip: _t('Make primary device', 'تبدیل به دستگاه اصلی'),
        icon: const Icon(Icons.shield_outlined, color: Colors.indigo),
        onPressed: _busy ? null : () => _makePrimary(device),
      );
    }
    if (!canTerminate) {
      return Icon(
        isPrimary ? Icons.lock_outline : Icons.remove_circle_outline,
        color: Colors.grey.withValues(alpha: 0.5),
        size: 20,
      );
    }
    return IconButton(
      tooltip: _t('End session', 'پایان نشست'),
      icon: const Icon(Icons.logout, color: Colors.red),
      onPressed: _busy ? null : () => _terminate(device),
    );
  }

  Widget _chip(String label, Color colour) => Container(
        margin: const EdgeInsetsDirectional.only(start: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(color: colour, fontSize: 11)),
      );

  Widget _explainer() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 18, color: Colors.blue),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _t('Like Telegram, signing in on a new device triggers an immediate alert in your chat list. The first device becomes primary, and other devices cannot remove it.', 'مانند تلگرام: ورود با دستگاه جدید بی‌درنگ در فهرست گفتگوها هشدار می‌دهد. اولین دستگاهِ واردشده، دستگاه اصلی حساب است و دستگاه‌های دیگر نمی‌توانند آن را حذف کنند.'),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
        ),
      );
}
