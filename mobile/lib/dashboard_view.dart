import 'package:flutter/material.dart';

ThemeData appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff167a68),
    brightness: brightness,
    primary: dark ? const Color(0xff70d5b9) : const Color(0xff126b59),
    surface: dark ? const Color(0xff1b1e22) : Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff111316)
        : const Color(0xfff3f5f6),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xff111316) : const Color(0xfff3f5f6),
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 54),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
  );
}

class DashboardView extends StatelessWidget {
  const DashboardView({
    super.key,
    required this.settings,
    required this.status,
    required this.connection,
    required this.ready,
    required this.busy,
    required this.checking,
    required this.onRefresh,
    required this.onConfigure,
    required this.onWake,
    required this.onCommand,
    this.devices = const [],
    this.selectedDevice = 0,
    this.onSelectDevice,
    this.onAddDevice,
    this.lastChecked,
    this.activity,
  });
  final List<Map<String, dynamic>> devices;
  final int selectedDevice;
  final Future<void> Function(int)? onSelectDevice;
  final Future<void> Function()? onAddDevice;
  final Map<String, dynamic> settings;
  final Map<String, dynamic>? status;
  final String connection;
  final bool ready, busy, checking;
  final Future<void> Function() onRefresh, onConfigure, onWake;
  final Future<void> Function(String) onCommand;
  final DateTime? lastChecked;
  final String? activity;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final online = status != null;
    final configured = settings.isNotEmpty;
    final seconds = (status?['uptime_seconds'] as num? ?? 0).toInt();
    final uptime =
        '${seconds ~/ 86400}d ${(seconds ~/ 3600) % 24}h ${(seconds ~/ 60) % 60}m';
    final addresses = (status?['addresses'] as List?)?.join(', ');
    final address = addresses?.isNotEmpty == true
        ? addresses!
        : Uri.tryParse(settings['url'] as String? ?? '')?.host;
    final statusColor = online ? colors.primary : colors.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(
        title: const Text('WakeDesk'),
        actions: [
          IconButton(
            tooltip: 'Refresh status',
            onPressed: configured && ready && !checking ? onRefresh : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Connection settings',
            onPressed: ready && !busy ? onConfigure : null,
            icon: const Icon(Icons.tune_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: RefreshIndicator(
              onRefresh: onRefresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                children: [
                  if (devices.isNotEmpty) ...[
                    InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Control PC',
                        enabled: ready && !busy && onSelectDevice != null,
                        prefixIcon: const Icon(Icons.computer_rounded),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: selectedDevice,
                          isExpanded: true,
                          isDense: true,
                          menuMaxHeight: 320,
                          itemHeight: null,
                          borderRadius: BorderRadius.circular(8),
                          dropdownColor: colors.surface,
                          selectedItemBuilder: (_) => [
                            for (var i = 0; i < devices.length; i++)
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: Text(
                                  devices[i]['name'] as String? ??
                                      'PC ${i + 1}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          items: [
                            for (var i = 0; i < devices.length; i++)
                              DropdownMenuItem(
                                value: i,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  child: Text(
                                    devices[i]['name'] as String? ??
                                        'PC ${i + 1}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                          ],
                          onChanged: ready && !busy && onSelectDevice != null
                              ? (value) {
                                  if (value != null) onSelectDevice!(value);
                                }
                              : null,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: ready && !busy ? onAddDevice : null,
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add PC'),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.desktop_windows_outlined,
                          size: 34,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              status?['name'] as String? ??
                                  settings['name'] as String? ??
                                  'My PC',
                              style: TextStyle(
                                fontSize: 25,
                                fontWeight: FontWeight.w700,
                                color: colors.onSurface,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(Icons.circle, size: 8, color: statusColor),
                                const SizedBox(width: 7),
                                Flexible(
                                  child: Text(
                                    connection,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: statusColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _Metric(
                          icon: Icons.lan_outlined,
                          label: 'IP address',
                          value: address?.isNotEmpty == true ? address! : '--',
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: _Metric(
                          icon: Icons.schedule_rounded,
                          label: 'Uptime',
                          value: online ? uptime : '--',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 24),
                  if (!configured) ...[
                    FilledButton.icon(
                      onPressed: ready ? onConfigure : null,
                      icon: const Icon(Icons.add_link_rounded),
                      label: const Text('Connect PC'),
                    ),
                    const SizedBox(height: 24),
                  ],
                  const _SectionTitle('Power & session'),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: ready && !busy && settings['mac'] != null
                        ? onWake
                        : null,
                    icon: const Icon(Icons.power_settings_new_rounded),
                    label: const Text('Power On'),
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final scale =
                          MediaQuery.textScalerOf(context).scale(14) / 14;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final action in const [
                            ('lock', 'Lock', Icons.lock_outline_rounded),
                            ('sleep', 'Sleep', Icons.bedtime_outlined),
                            ('restart', 'Restart', Icons.restart_alt_rounded),
                            (
                              'shutdown',
                              'Shutdown',
                              Icons.power_settings_new_rounded,
                            ),
                          ])
                            SizedBox(
                              width: (constraints.maxWidth - 12) / 2,
                              height: (100 + (scale - 1).clamp(0, 4) * 38)
                                  .ceilToDouble(),
                              child: OutlinedButton(
                                onPressed: online && !busy
                                    ? () => onCommand(action.$1)
                                    : null,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: action.$1 == 'shutdown'
                                      ? colors.error
                                      : colors.onSurface,
                                  backgroundColor: colors.surface,
                                  disabledForegroundColor: colors
                                      .onSurfaceVariant
                                      .withValues(alpha: .55),
                                  side: BorderSide(
                                    color: colors.outlineVariant,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(action.$3, size: 25),
                                    const SizedBox(height: 10),
                                    Text(
                                      action.$2,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 22),
                  if (busy) const LinearProgressIndicator(minHeight: 3),
                  if (activity != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.history_rounded,
                            size: 16,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              activity!,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (lastChecked != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Last checked ${TimeOfDay.fromDateTime(lastChecked!).format(context)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (configured) ...[
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 12),
                    Theme(
                      data: Theme.of(context)
                          .copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(bottom: 12),
                        title: const Text(
                          'Connection details',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        leading: Icon(
                          Icons.link_rounded,
                          color: colors.onSurfaceVariant,
                        ),
                        children: [
                          for (final entry in {
                            'Agent': settings['url'],
                            'MAC address': settings['mac'],
                            'Broadcast': settings['broadcast'],
                          }.entries)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    entry.key,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  SelectableText(
                                    entry.value as String? ?? '--',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label, value;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: colors.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: colors.onSurface,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Text(
    title,
    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
  );
}
