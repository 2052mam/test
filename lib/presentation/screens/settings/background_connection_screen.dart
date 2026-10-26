import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/utils/app_locale.dart';
import '../../../data/services/api_service.dart';
import '../../../data/services/connection_service.dart';
import '../../../data/services/push_service.dart';
import '../../../data/services/system_settings_service.dart';

/// Telegram-style background-connection settings: the keep-alive service
/// plus the system exemptions (battery + hibernation + autostart) that
/// decide whether notifications arrive after the app is swiped away, with
/// an optional FCM instant-push row on top.
class BackgroundConnectionScreen extends StatefulWidget {
  const BackgroundConnectionScreen({super.key});

  @override
  State<BackgroundConnectionScreen> createState() =>
      _BackgroundConnectionScreenState();
}

class _BackgroundConnectionScreenState
    extends State<BackgroundConnectionScreen> {
  bool _enabled = true;
  bool _running = false;
  bool _batteryExempt = false;
  bool _hibernationExempt = false;
  bool _loaded = false;
  bool _busy = false;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final enabled = await ConnectionService.isEnabled();
    final running = await ConnectionService.isRunning;
    final exempt = await ConnectionService.isBatteryExempt;
    final hibernation = await SystemSettingsService.isHibernationExempt();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _running = running;
      _batteryExempt = exempt;
      _hibernationExempt = hibernation;
      _loaded = true;
    });
  }

  Future<void> _toggle(bool value) async {
    setState(() {
      _enabled = value;
      _busy = true;
    });
    await ConnectionService.setEnabled(value);
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _fixBattery() async {
    await ConnectionService.requestBatteryExemption();
    // The system dialog resolves asynchronously; re-read on return.
    await Future.delayed(const Duration(seconds: 1));
    await _refresh();
  }

  Future<void> _fixHibernation() async {
    final ok = await SystemSettingsService.setHibernationExempt();
    await _refresh();
    if (!mounted) return;
    if (!ok) {
      // The ROM refused the programmatic fix: open App Info where the
      // "Pause app activity if unused" toggle lives.
      await SystemSettingsService.openAppInfo();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocale.pick('گزینه «توقف فعالیت برنامه در صورت عدم استفاده» را خاموش کنید، بعد برگردید.', 'Turn off “Pause app activity if unused”, then return here.'),
          ),
        ),
      );
      await _refresh();
    }
  }

  /// Fires a self-test FCM tick via the server. Success proves the whole
  /// push chain (server credentials -> FCM -> this phone) in seconds.
  Future<void> _testPush() async {
    if (_testing) return;
    setState(() => _testing = true);
    try {
      final res = await ApiService().post('/notifications/test', {});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocale.pick('اعلان آزمایشی ارسال شد (${res['delivered'] ?? 0} دستگاه) — باید ظرف چند ثانیه برسد.', 'Test notification sent to ${res['delivered'] ?? 0} device(s); it should arrive within seconds.'),
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.statusCode == 404
                ? AppLocale.pick('سرویس پوش روی سرور پیکربندی نشده — اعلان‌ها از طریق اتصال پس‌زمینه می‌رسند.', 'Push is not configured on the server; notifications use the background connection.')
                : AppLocale.pick('ارسال ناموفق بود: ${e.message}', 'Could not send: ${e.message}'),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocale.pick('ارسال ناموفق بود. اتصال اینترنت را بررسی کنید.', 'Could not send. Check your internet connection.')),
        ),
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _openAutoStart() async {
    final opened = await SystemSettingsService.openAutoStartSettings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          opened
              ? AppLocale.pick('در تنظیمات بازشده، «شروع خودکار» را برای Reyno فعال کنید.', 'Enable autostart for Reyno in the settings that opened.')
              : AppLocale.pick('باز کردن تنظیمات ممکن نشد. لطفاً دستی در تنظیمات گوشی اجازه شروع خودکار بدهید.', 'Could not open settings. Enable autostart for Reyno manually in your phone settings.'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final healthy =
        _enabled && _running && _batteryExempt && _hibernationExempt;
    return Scaffold(
      appBar: AppBar(title: Text(AppLocale.pick('اتصال پس‌زمینه', 'Background connection'))),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    color: healthy
                        ? Colors.green.withValues(alpha: 0.08)
                        : Colors.orange.withValues(alpha: 0.08),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(
                            healthy
                                ? Icons.check_circle_outline
                                : Icons.warning_amber_outlined,
                            color: healthy ? Colors.green : Colors.orange,
                            size: 32,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              healthy
                                  ? AppLocale.pick('اتصال پس‌زمینه فعال است. پیام‌ها حتی با بسته بودن برنامه می‌رسند.', 'Background connection is active. Messages can arrive while the app is closed.')
                                  : AppLocale.pick('برای دریافت پیام وقتی برنامه بسته است، موارد زیر را کامل کنید.', 'Complete the steps below to receive messages while the app is closed.'),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (!Platform.isAndroid)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          AppLocale.pick('سرویس نگه‌دارنده اتصال مخصوص اندروید است.', 'The keep-alive connection service is available on Android only.'),
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                  SwitchListTile(
                    secondary: const Icon(Icons.sync_outlined),
                    title: Text(AppLocale.pick('اتصال پس‌زمینه', 'Background connection')),
                    subtitle: Text(
                      AppLocale.pick('سرویس سبک نگه‌دارنده (مثل تلگرام) — با اعلان دائمی «متصل». خاموش = اعلان فقط در بازه‌های ~۱۵ دقیقه‌ای.', 'Lightweight keep-alive service (like Telegram) with a persistent Connected notification. Off: checks about every 15 minutes.'),
                      style: TextStyle(fontSize: 12),
                    ),
                    value: _enabled,
                    onChanged: _busy ? null : _toggle,
                  ),
                  const Divider(),
                  ListTile(
                    leading: Icon(
                      _running
                          ? Icons.play_circle_outline
                          : Icons.pause_circle_outline,
                      color: _running ? Colors.green : Colors.grey,
                    ),
                    title: Text(AppLocale.pick('وضعیت سرویس', 'Service status')),
                    subtitle: Text(
                      _running ? AppLocale.pick('در حال اجرا', 'Running') : AppLocale.pick('متوقف شده', 'Stopped'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : TextButton(
                            onPressed: _refresh,
                            child: Text(AppLocale.pick('به‌روزرسانی', 'Refresh')),
                          ),
                  ),
                  ListTile(
                    leading: Icon(
                      _batteryExempt
                          ? Icons.battery_saver_outlined
                          : Icons.battery_alert_outlined,
                      color: _batteryExempt ? Colors.green : Colors.orange,
                    ),
                    title: Text(AppLocale.pick('معافیت از بهینه‌سازی باتری', 'Battery optimization exemption')),
                    subtitle: Text(
                      _batteryExempt
                          ? AppLocale.pick('فعال است — اتصال در حالت خواب گوشی هم کار می‌کند.', 'Enabled — connection can work while the phone sleeps.')
                          : AppLocale.pick('لازم است — بدون آن، شیائومی/هواوی اتصال را در خواب می‌بندند.', 'Required — some phone makers stop background connections without it.'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: _batteryExempt
                        ? const Icon(Icons.check,
                            color: Colors.green, size: 20)
                        : FilledButton.tonal(
                            onPressed: _fixBattery,
                            child: Text(AppLocale.pick('فعال‌سازی', 'Enable')),
                          ),
                  ),
                  ListTile(
                    leading: Icon(
                      _hibernationExempt
                          ? Icons.pause_circle_outline
                          : Icons.play_circle_outline,
                      color:
                          _hibernationExempt ? Colors.green : Colors.orange,
                    ),
                    title: Text(AppLocale.pick('عدم توقف خودکار برنامه', 'Prevent automatic app suspension')),
                    subtitle: Text(
                      _hibernationExempt
                          ? AppLocale.pick('فعال است — «توقف فعالیت در صورت عدم استفاده» خاموش است.', 'Enabled — “Pause app activity if unused” is off.')
                          : AppLocale.pick('لازم است — اگر روشن بماند، اندروید اتصال را بعد از بستن برنامه می‌بندد.', 'Required — Android may stop the connection after you close the app.'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: _hibernationExempt
                        ? const Icon(Icons.check,
                            color: Colors.green, size: 20)
                        : FilledButton.tonal(
                            onPressed: _fixHibernation,
                            child: Text(AppLocale.pick('رفع', 'Fix')),
                          ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.rocket_launch_outlined,
                        color: Colors.blue),
                    title: Text(AppLocale.pick('شروع خودکار (Autostart)', 'Autostart')),
                    subtitle: Text(
                      AppLocale.pick('در گوشی‌های شیائومی/هواوی/اوپو/ویوو: اجازه شروع خودکار تا اتصال بعد از بستن برنامه زنده بماند.', 'On some devices, allow autostart so the connection can stay alive after closing the app.'),
                      style: TextStyle(fontSize: 12),
                    ),
                    trailing: FilledButton.tonal(
                      onPressed: _openAutoStart,
                      child: Text(AppLocale.pick('باز کردن', 'Open')),
                    ),
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.bolt_outlined,
                      color: PushService.isSupported
                          ? Colors.green
                          : Colors.grey,
                    ),
                    title: Text(AppLocale.pick('اعلان فوری (پوش)', 'Instant push notifications')),
                    subtitle: Text(
                      PushService.isSupported
                          ? AppLocale.pick('فعال است — بیدارسازی فوری حتی در خواب عمیق گوشی.', 'Active — can wake the phone even during deep sleep.')
                          : AppLocale.pick('در این نصب فعال نیست — اتصال پس‌زمینه جایگزین آن است.', 'Not enabled in this build — background connection is the fallback.'),
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: _testing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : FilledButton.tonal(
                            onPressed: PushService.isSupported
                                ? _testPush
                                : null,
                            child: Text(AppLocale.pick('تست', 'Test')),
                          ),
                  ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      AppLocale.pick('نکته باتری: این اتصال هر ~۲۰ ثانیه یک بررسی سبک انجام می‌دهد؛ مصرف آن در حد نگه‌داشتن اتصال تلگرام است. اعلان فوری (پوش) در صورت فعال بودن، بیدارسازی را سریع‌تر می‌کند؛ بدون آن هم اتصال بالا به‌تنهایی کار می‌کند، پس تحریم و فیلترینگ اثری روی آن ندارد.', 'Battery note: background connection performs a lightweight check about every 20 seconds. Push notifications can wake the app faster when available; background connection works independently.'),
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
