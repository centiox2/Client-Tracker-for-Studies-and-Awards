part of 'reports_screen.dart';

/// Opens TV mode: today's numbers in large type for a screen on the wall,
/// updating as numbers come in. Esc or the close button leaves it.
Future<void> openTvView(BuildContext context) {
  enterFullscreen();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => const _TvView(),
    ),
  );
}

class _TvView extends ConsumerStatefulWidget {
  const _TvView();

  @override
  ConsumerState<_TvView> createState() => _TvViewState();
}

class _TvViewState extends ConsumerState<_TvView> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The clock, and the day rolling over at midnight.
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    exitFullscreen();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = DateTime.now();
    final day = _lastWeekday(now);
    final isToday = _sameDay(day, now);
    final monday = day.subtract(Duration(days: day.weekday - 1));
    final today = ref.watch(reportProvider((day, day)));
    final week = ref.watch(
      reportProvider((monday, monday.add(const Duration(days: 4)))),
    );
    final weekSoFar = ref.watch(reportProvider((monday, day)));
    final month = ref.watch(
      reportProvider((DateTime(day.year, day.month, 1), day)),
    );
    final target = ref.watch(dailyTargetProvider);
    final revenueToday = ref.watch(revenueDaysProvider((day, day))).single;
    final currency = ref.watch(currencyProvider);
    final seen = today.staff.where((s) => s.total > 0).toList();
    final holiday = today.days.isNotEmpty && today.days.first.isHoliday;

    Widget big(String value, {Color? color, double size = 120}) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: AnimatedValueText(
        value,
        style: Dt.tab(
          theme.textTheme.displayLarge!,
        ).copyWith(fontSize: size, fontWeight: FontWeight.w700, color: color),
      ),
    );
    Widget caption(String text) => Text(
      text,
      style: theme.textTheme.titleMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w500,
      ),
    );
    Widget stat(String label, String value, {Color? color}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        caption(label),
        big(value, color: color, size: 56),
      ],
    );

    // [fill]: the wall-screen layout, where the chart sits at the bottom.
    // Otherwise (a phone) everything stacks and scrolls.
    Widget left({required bool fill}) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        caption(
          isToday
              ? 'Clients today'
              : 'Clients on ${DateFormat('EEEE').format(day)}',
        ),
        big(holiday ? 'Holiday' : '${today.total}', size: 140),
        if (target != null && !holiday)
          SizedBox(
            width: 360,
            child: _TargetBar(
              value: today.total.toDouble(),
              target: target.toDouble(),
            ),
          ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 48,
          runSpacing: 16,
          children: [
            stat(
              'New',
              '${today.newClients}',
              color: Dt.newGreen(theme.brightness),
            ),
            stat(
              'Existing',
              '${today.existingClients}',
              color: Dt.existingBlue(theme.brightness),
            ),
            stat('This week', '${weekSoFar.total}'),
            stat(DateFormat('MMMM').format(day), '${month.total}'),
            if (ref.watch(seesRevenueProvider))
              stat(
                isToday
                    ? 'Revenue today'
                    : 'Revenue ${DateFormat('EEEE').format(day)}',
                formatMoney(revenueToday.totalCents, currency),
              ),
          ],
        ),
        if (fill) const Spacer() else const SizedBox(height: 24),
        if (week.days.isNotEmpty) _DayBars(days: week.days, height: 220),
      ],
    );

    Widget right({required bool fill}) => Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rLg),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            isToday ? 'Who’s seeing clients' : 'Who saw clients',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (seen.isEmpty)
            caption(holiday ? 'The whole team is off.' : 'No clients yet.')
          else
            for (final s in seen.take(10))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    Text(
                      '${s.newClients}',
                      style: Dt.tab(theme.textTheme.headlineSmall!)
                          .copyWith(color: Dt.newGreen(theme.brightness)),
                    ),
                    const SizedBox(width: 18),
                    Text(
                      '${s.existingClients}',
                      style: Dt.tab(theme.textTheme.headlineSmall!)
                          .copyWith(color: Dt.existingBlue(theme.brightness)),
                    ),
                    SizedBox(
                      width: 72,
                      child: Text(
                        '${s.total}',
                        textAlign: TextAlign.right,
                        style: Dt.tab(theme.textTheme.headlineMedium!)
                            .copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
          if (fill) const Spacer() else const SizedBox(height: 12),
          const NewExistingLegend(),
        ],
      ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, viewport) {
                final narrow = viewport.maxWidth < 900;
                final header = Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(Dt.rSm),
                      child: Image.asset(Dt.logoAsset, width: 40, height: 40),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        Dt.companyName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    if (isToday && !narrow) ...[
                      LiveDot(
                        color: Dt.statusGreen(theme.brightness),
                        size: 10,
                        pingKey: week.lastUpdated,
                      ),
                      const SizedBox(width: 8),
                      Text('Live', style: theme.textTheme.titleMedium),
                      const SizedBox(width: 24),
                    ],
                    Text(
                      DateFormat(narrow ? 'HH:mm' : 'EEEE d MMMM · HH:mm')
                          .format(now),
                      style: Dt.tab(theme.textTheme.titleLarge!),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      tooltip: 'Leave TV mode (Esc)',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                );
                if (narrow) {
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                    children: [
                      header,
                      const SizedBox(height: 20),
                      left(fill: false),
                      const SizedBox(height: 20),
                      right(fill: false),
                    ],
                  );
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(32, 20, 32, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header,
                      const SizedBox(height: 24),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 3, child: left(fill: true)),
                            const SizedBox(width: 32),
                            Expanded(flex: 2, child: right(fill: true)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
