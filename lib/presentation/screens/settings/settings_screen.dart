import 'dart:async';

import '../../widgets/chat/join_privacy_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/services/storage_service.dart';
import '../../../core/utils/app_locale.dart';

import '../../../data/services/api_service.dart';
import '../../../data/services/chat_navigation.dart';
import '../../../data/services/background_poll_service.dart';
import '../../../data/services/connection_service.dart';
import '../../../data/services/notification_service.dart';
import '../../../data/services/sound_service.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/chat/chat_avatar.dart';
import '../../providers/locale_provider.dart';
import '../../providers/theme_provider.dart';
import '../chat/chat_screen.dart';
import '../profile/profile_screen.dart';
import 'account_switcher_screen.dart';
import 'archive_lock_screen.dart';
import 'background_connection_screen.dart';
import 'phone_recovery_screen.dart';
import 'device_management_screen.dart';
import 'offline_media_screen.dart';
import 'admin_reports_screen.dart';
import 'sponsored_channels_screen.dart';
import 'terms_screen.dart';
import '../auth/two_factor_security_screen.dart';
import '../home/archived_chats_screen.dart';
import '../../widgets/chat/chat_labels.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Widget _settingsGroup(BuildContext context, {String? title, required List<Widget> children}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 22, top: 16, bottom: 6),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: isDark ? const Color(0xFF64B5F6) : theme.colorScheme.primary,
                letterSpacing: 0.2,
              ),
            ),
          ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF17212B) : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isDark ? const Color(0xFF27384A) : const Color(0xFFE2E8F0),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.03),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Column(children: children),
          ),
        ),
      ],
    );
  }

  Widget _iconBadge(IconData icon, Color color) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFa = ref.watch(localeProvider).languageCode == 'fa';
    final themeMode = ref.watch(themeModeProvider);
    final palette = ref.watch(themePaletteProvider);
    final user = ref.watch(authNotifierProvider).valueOrNull;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(isFa ? 'تنظیمات' : 'Settings', style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            // User Profile Header Card
            if (user != null)
              Container(
                margin: const EdgeInsets.fromLTRB(14, 4, 14, 10),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.colorScheme.primary.withValues(alpha: 0.12),
                      theme.cardColor,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.25),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    ChatAvatar(
                      title: user.displayName,
                      url: user.avatarUrl,
                      token: StorageService.getToken(),
                      radius: 32,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user.displayName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 17.5,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            user.handle,
                            style: TextStyle(
                              color: theme.textTheme.bodySmall?.color,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (user.mobileNumber != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              user.mobileNumber!,
                              textDirection: TextDirection.ltr,
                              style: TextStyle(
                                color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.8),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      ),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const ProfileScreen()),
                        );
                      },
                      child: Text(isFa ? 'ویرایش' : 'Edit'),
                    ),
                  ],
                ),
              ),

            // Section: Connection & Sync
            _settingsGroup(
              context,
              title: isFa ? 'ارتباط و صداها' : 'Connection & Sounds',
              children: [
                const _NotificationTile(),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                const _SoundEffectsTile(),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  leading: _iconBadge(Icons.sync_rounded, const Color(0xFF00ACC1)),
                  title: Text(AppLocale.pick('اتصال پس‌زمینه', 'Background connection'), style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    AppLocale.pick('دریافت پیام وقتی برنامه بسته است (مثل تلگرام)', 'Receive messages while the app is closed (like Telegram)'),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const BackgroundConnectionScreen(),
                    ),
                  ),
                ),
              ],
            ),

            // Section: Appearance
            _settingsGroup(
              context,
              title: isFa ? 'ظاهر و شخصی‌سازی' : 'Appearance & Personalization',
              children: [
                ListTile(
                  leading: _iconBadge(Icons.palette_rounded, const Color(0xFF8B5CF6)),
                  title: Text(isFa ? 'تم' : 'Theme', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    themeMode == ThemeMode.dark
                        ? (isFa ? 'تاریک' : 'Dark')
                        : themeMode == ThemeMode.light
                        ? (isFa ? 'روشن' : 'Light')
                        : (isFa ? 'سیستم' : 'System'),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    showModalBottomSheet(
                      context: context,
                      builder: (_) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.wb_sunny_rounded, color: Colors.orange),
                              title: Text(isFa ? 'روشن' : 'Light'),
                              trailing: themeMode == ThemeMode.light ? const Icon(Icons.check, color: Colors.blue) : null,
                              onTap: () {
                                ref
                                    .read(themeModeProvider.notifier)
                                    .setThemeMode(ThemeMode.light);
                                Navigator.pop(context);
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.nightlight_round, color: Colors.indigo),
                              title: Text(isFa ? 'تاریک' : 'Dark'),
                              trailing: themeMode == ThemeMode.dark ? const Icon(Icons.check, color: Colors.blue) : null,
                              onTap: () {
                                ref
                                    .read(themeModeProvider.notifier)
                                    .setThemeMode(ThemeMode.dark);
                                Navigator.pop(context);
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.settings_suggest_rounded, color: Colors.grey),
                              title: Text(isFa ? 'سیستم' : 'System'),
                              trailing: themeMode == ThemeMode.system ? const Icon(Icons.check, color: Colors.blue) : null,
                              onTap: () {
                                ref
                                    .read(themeModeProvider.notifier)
                                    .setThemeMode(ThemeMode.system);
                                Navigator.pop(context);
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  leading: _iconBadge(Icons.language_rounded, const Color(0xFF10B981)),
                  title: Text(isFa ? 'زبان' : 'Language', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(isFa ? 'فارسی' : 'English'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    final choice = await showDialog<String>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(isFa ? 'انتخاب زبان' : 'Choose language'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              title: Text(isFa ? 'فارسی' : 'Persian'),
                              leading: Radio<String>(
                                value: 'fa',
                                groupValue: isFa ? 'fa' : 'en',
                                onChanged: (v) => Navigator.pop(ctx, v),
                              ),
                              onTap: () => Navigator.pop(ctx, 'fa'),
                            ),
                            ListTile(
                              title: const Text('English'),
                              leading: Radio<String>(
                                value: 'en',
                                groupValue: isFa ? 'fa' : 'en',
                                onChanged: (v) => Navigator.pop(ctx, v),
                              ),
                              onTap: () => Navigator.pop(ctx, 'en'),
                            ),
                          ],
                        ),
                      ),
                    );
                    if (choice == 'fa') {
                      ref
                          .read(localeProvider.notifier)
                          .setLocale(const Locale('fa', 'IR'));
                    } else if (choice == 'en') {
                      ref
                          .read(localeProvider.notifier)
                          .setLocale(const Locale('en', 'US'));
                    }
                  },
                ),
              ],
            ),

            // Section: Privacy & Security
            _settingsGroup(
              context,
              title: isFa ? 'امنیت و حریم خصوصی' : 'Privacy & Security',
              children: [
                ListTile(
                  leading: _iconBadge(Icons.visibility_off_rounded, const Color(0xFF64748B)),
                  title: Text(isFa ? 'حالت گوست' : 'Ghost Mode', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    isFa
                        ? 'پنهان کردن وضعیت آنلاین و آخرین بازدید'
                        : 'Hide online status & last seen',
                  ),
                  trailing: Switch(
                    value: !(user?.showLastSeen ?? true),
                    onChanged: (v) async {
                      try {
                        await ApiService().put('/users/me', {'show_last_seen': !v});
                        ref.read(authNotifierProvider.notifier).checkSession();
                      } catch (_) {}
                    },
                  ),
                ),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                const JoinPrivacyTile(),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  key: const ValueKey('two-factor-security-tile'),
                  leading: _iconBadge(Icons.security_rounded, const Color(0xFF2563EB)),
                  title: Text(isFa ? 'تأیید دو مرحله‌ای' : 'Two-Step Verification', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    user?.isTwoFactorEnabled == true
                        ? (isFa ? 'Google Authenticator فعال است' : 'Google Authenticator is enabled')
                        : (isFa ? 'اختیاری — ورود اصلی با پیامک است' : 'Optional — SMS remains the primary sign-in'),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TwoFactorSecurityScreen()),
                  ),
                ),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  key: const ValueKey('phone-recovery-tile'),
                  leading: _iconBadge(Icons.sms_outlined, const Color(0xFF059669)),
                  title: Text(isFa ? 'شمارهٔ بازیابی' : 'Recovery phone', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(isFa ? 'تأیید شماره برای بازیابی امن حساب' : 'Verify your phone for account recovery'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PhoneRecoveryScreen()),
                  ),
                ),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  key: const ValueKey('archive-lock-tile'),
                  leading: _iconBadge(Icons.lock_rounded, const Color(0xFFF59E0B)),
                  title: Text(ChatLabels.of(context).archiveLock, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(ChatLabels.of(context).archiveLockHint),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ArchiveLockScreen()),
                  ),
                ),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  key: const ValueKey('archived-chats-tile'),
                  leading: _iconBadge(Icons.archive_rounded, const Color(0xFF6B7280)),
                  title: Text(ChatLabels.of(context).archivedChats, style: const TextStyle(fontWeight: FontWeight.w600)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openArchivedChats(context, ref),
                ),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  leading: _iconBadge(Icons.devices_rounded, const Color(0xFF3B82F6)),
                  title: Text(isFa ? 'دستگاه‌ها و نشست‌ها' : 'Devices & Sessions', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(isFa ? 'مدیریت ورود چنددستگاهی مانند تلگرام' : 'Manage multi-device logins like Telegram'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DeviceManagementScreen())),
                ),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  leading: _iconBadge(Icons.forward_rounded, const Color(0xFF14B8A6)),
                  title: Text(isFa ? 'اجازه فوروارد پیام‌های من' : 'Allow forwarding my messages', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(isFa ? 'دیگران بتوانند پیام‌های شما را فوروارد کنند' : 'Others can forward your messages'),
                  trailing: Switch(
                    value: user?.allowForwarding ?? true,
                    onChanged: (v) async {
                      try {
                        await ApiService().put('/users/me', {'allow_forwarding': v});
                        ref.read(authNotifierProvider.notifier).checkSession();
                      } catch (_) {}
                    },
                  ),
                ),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  leading: _iconBadge(Icons.photo_rounded, const Color(0xFFA855F7)),
                  title: Text(isFa ? 'نمایش عکس پروفایل' : 'Show Profile Photo', style: const TextStyle(fontWeight: FontWeight.w600)),
                  trailing: Switch(
                    value: user?.showProfilePhoto ?? true,
                    onChanged: (v) async {
                      try {
                        await ApiService().put('/users/me', {
                          'show_profile_photo': v,
                        });
                        ref.read(authNotifierProvider.notifier).checkSession();
                      } catch (_) {}
                    },
                  ),
                ),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  leading: _iconBadge(Icons.block_rounded, const Color(0xFFEF4444)),
                  title: Text(isFa ? 'افراد بلاک شده' : 'Blocked Users', style: const TextStyle(fontWeight: FontWeight.w600)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    try {
                      final res = await ApiService().get('/users/blocked');
                      final users = res['users'] as List? ?? [];
                      if (!context.mounted) return;
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(isFa ? 'بلاک شده‌ها' : 'Blocked Users'),
                          content: SizedBox(
                            width: double.maxFinite,
                            child: users.isEmpty
                                ? Text(isFa ? 'کسی بلاک نشده' : 'No blocked users')
                                : ListView.builder(
                                    shrinkWrap: true,
                                    itemCount: users.length,
                                    itemBuilder: (_, i) {
                                      final u = users[i];
                                      return ListTile(
                                        title: Text(u['display_name'] ?? ''),
                                        subtitle: Text('@${u['username'] ?? ''}'),
                                        trailing: TextButton(
                                          child: Text(
                                            isFa ? 'آنبلاک' : 'Unblock',
                                            style: const TextStyle(color: Colors.red),
                                          ),
                                          onPressed: () async {
                                            await ApiService().post(
                                              '/users/unblock/${u['id']}',
                                              {},
                                            );
                                            Navigator.pop(ctx);
                                          },
                                        ),
                                      );
                                    },
                                  ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: Text(isFa ? 'بستن' : 'Close'),
                            ),
                          ],
                        ),
                      );
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(e.toString())));
                      }
                    }
                  },
                ),
              ],
            ),

            // Section: Data & Storage
            _settingsGroup(
              context,
              title: isFa ? 'داده‌ها و ذخیره‌سازی' : 'Data & Storage',
              children: [
                ListTile(
                  key: const ValueKey('offline-media-tile'),
                  leading: _iconBadge(Icons.download_done_rounded, const Color(0xFF10B981)),
                  title: Text(isFa ? 'حافظه آفلاین رسانه' : 'Offline media storage', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    isFa
                        ? 'نگه‌داری عکس‌ها و فایل‌های ارسالی روی همین دستگاه (پشتیبان در برابر از دست رفتن اطلاعات سرور)'
                        : 'Keeps sent media on this device as a safeguard against server data loss',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const OfflineMediaScreen()),
                  ),
                ),
              ],
            ),

            // Section: Account & Management
            _settingsGroup(
              context,
              title: isFa ? 'حساب کاربری و مدیریت' : 'Account & Management',
              children: [
                ListTile(
                  leading: _iconBadge(Icons.switch_account_rounded, const Color(0xFF2563EB)),
                  title: Text(isFa ? 'مدیریت اکانت‌ها' : 'Accounts', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    isFa ? 'سوییچ بین حداکثر ۳ اکانت' : 'Switch up to 3 accounts',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const AccountSwitcherScreen(),
                      ),
                    );
                  },
                ),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  leading: _iconBadge(Icons.report_problem_rounded, const Color(0xFFF97316)),
                  title: Text(isFa ? 'گزارش‌ها (مدیریت)' : 'Reports (Admin)', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(isFa ? 'بررسی گزارش کاربران و گروه‌ها/کانال‌ها' : 'Review user & chat reports'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdminReportsScreen())),
                ),
                if (user?.isAdmin == true) ...[
                  Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                  ListTile(
                    leading: _iconBadge(Icons.campaign_rounded, const Color(0xFFEAB308)),
                    title: Text(isFa ? 'کانال‌های اسپانسرشده' : 'Sponsored channels', style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(isFa ? 'مدیریت کانال‌های تبلیغاتی (مدیر کل)' : 'Manage promoted channels (super admin)', style: const TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SponsoredChannelsScreen()),
                    ),
                  ),
                ],
              ],
            ),

            // Section: Help & Information
            _settingsGroup(
              context,
              title: isFa ? 'راهنما و اطلاعات' : 'Help & Information',
              children: [
                ListTile(
                  leading: _iconBadge(Icons.support_agent_rounded, const Color(0xFF00ACC1)),
                  title: Text(isFa ? 'چت با پشتیبانی' : 'Support Chat', style: const TextStyle(fontWeight: FontWeight.w600)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    try {
                      final res = await ApiService().post('/chats/support', {});
                      final chatId = res['chat_id'] as String;
                      if (context.mounted) {
                        unawaited(ChatNavigation.open(
                          context,
                          chatId: chatId,
                          builder: (_) => ChatScreen(
                            chatId: chatId,
                            title: isFa ? 'پشتیبانی' : 'Support',
                            chatType: 'support',
                          ),
                        ));
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(e.toString())));
                      }
                    }
                  },
                ),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  leading: _iconBadge(Icons.bookmark_rounded, const Color(0xFF3B82F6)),
                  title: Text(isFa ? 'پیام‌های ذخیره‌شده' : 'Saved Messages', style: const TextStyle(fontWeight: FontWeight.w600)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    try {
                      final res = await ApiService().post('/chats/saved', {});
                      final chatId = res['chat_id'] as String;
                      if (context.mounted) {
                        unawaited(ChatNavigation.open(
                          context,
                          chatId: chatId,
                          builder: (_) => ChatScreen(
                            chatId: chatId,
                            title: isFa ? 'پیام‌های ذخیره‌شده' : 'Saved Messages',
                            chatType: 'saved',
                          ),
                        ));
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(e.toString())));
                      }
                    }
                  },
                ),
                Divider(height: 1, indent: 56, color: theme.dividerColor.withValues(alpha: 0.2)),
                ListTile(
                  leading: _iconBadge(Icons.article_rounded, const Color(0xFF64748B)),
                  title: Text(isFa ? 'قوانین و مقررات' : 'Rules & Terms', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(isFa ? 'قوانین استفاده از پیام‌رسان' : 'Messenger rules of use'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TermsScreen()),
                  ),
                ),
              ],
            ),

            // Logout
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.red.withValues(alpha: 0.25)),
                ),
                tileColor: Colors.red.withValues(alpha: 0.06),
                leading: _iconBadge(Icons.logout_rounded, Colors.red),
                title: Text(
                  isFa ? 'خروج از حساب' : 'Logout',
                  style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w700),
                ),
                onTap: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(isFa ? 'خروج' : 'Logout'),
                      content: Text(isFa ? 'آیا مطمئن هستید؟' : 'Are you sure?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(isFa ? 'خیر' : 'No'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: Text(isFa ? 'بله' : 'Yes', style: const TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await ref.read(authNotifierProvider.notifier).logout();
                  }
                },
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// Master notification switch (Item 3). Works without any push server: the
/// app polls while alive and a WorkManager task polls while it is killed.
/// No Firebase account, no Google services, no sanction exposure.
class _NotificationTile extends StatefulWidget {
  const _NotificationTile();

  @override
  State<_NotificationTile> createState() => _NotificationTileState();
}

class _NotificationTileState extends State<_NotificationTile> {
  bool _enabled = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    NotificationService().isEnabled().then((v) {
      if (mounted) setState(() => {_enabled = v, _loaded = true});
    });
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    if (value) {
      await NotificationService().requestPermissions();
      await ConnectionService.startIfEnabled();
      await BackgroundPollService.start();
    } else {
      await ConnectionService.stop();
      await BackgroundPollService.stop();
    }
    await NotificationService().setEnabled(value);
    try {
      await ApiService().post('/notifications/register', {
        'notifications_enabled': value,
      });
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFF3B82F6).withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          _enabled
              ? Icons.notifications_active_rounded
              : Icons.notifications_off_rounded,
          color: const Color(0xFF3B82F6),
          size: 20,
        ),
      ),
      title: Text(AppLocale.pick('اعلان پیام‌های جدید', 'New message notifications'), style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        AppLocale.pick('نمایش اعلان حتی وقتی برنامه بسته است (بدون نیاز به گوگل)', 'Show notifications even when the app is closed (no Google services required)'),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: _loaded
          ? Switch(value: _enabled, onChanged: _toggle)
          : const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
    );
  }
}

class _SoundEffectsTile extends StatefulWidget {
  const _SoundEffectsTile();

  @override
  State<_SoundEffectsTile> createState() => _SoundEffectsTileState();
}

class _SoundEffectsTileState extends State<_SoundEffectsTile> {
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    _enabled = SoundService().isEnabled;
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    await SoundService().setEnabled(value);
    if (value) {
      unawaited(SoundService().playMessageSent());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFF10B981).withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          _enabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
          color: const Color(0xFF10B981),
          size: 20,
        ),
      ),
      title: Text(AppLocale.pick('افکت‌های صوتی پیام‌ها', 'Message sound effects'), style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        AppLocale.pick('صدای ارسال و دریافت پیام و واکنش‌ها', 'Sounds for sending, receiving, and reacting to messages'),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Switch(value: _enabled, onChanged: _toggle),
    );
  }
}

