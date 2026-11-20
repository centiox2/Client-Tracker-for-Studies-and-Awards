import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/app_theme.dart';
import '../../widgets/clarity.dart';

/// Renders the server's fixed report sections and verified table values.
class TemplateReportDocument extends StatelessWidget {
  const TemplateReportDocument({
    super.key,
    required this.template,
    required this.detailed,
  });

  final Map template;
  final bool detailed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.clarity;
    final blocks = template[detailed ? 'detailed' : 'quick'];
    return ClarityCard(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 16 : 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            detailed
                ? 'S&A Hub · Detailed Daily Report'
                : 'S&A Hub · Quick View',
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          Text(
            '${template['meta'] ?? '—'}',
            style: theme.textTheme.bodySmall?.copyWith(color: colors.textMuted),
          ),
          if (blocks is List)
            for (final block in blocks.whereType<Map>())
              _ReportBlock(block: block, compact: !detailed),
        ],
      ),
    );
  }
}

class _ReportBlock extends StatelessWidget {
  const _ReportBlock({required this.block, required this.compact});

  final Map block;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final styles = Theme.of(context).textTheme;
    final colors = context.clarity;
    final text = '${block['text'] ?? ''}';
    final kind = block['kind'];
    final child = switch (kind) {
      'heading' => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 1, color: colors.borderSubtle),
          const SizedBox(height: 8),
          Text(
            text,
            style: styles.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
      'label' => Text(text, style: styles.titleSmall),
      'text' => Text(text, style: styles.bodyMedium),
      'table' => _ReportTable(block: block, compact: compact),
      'bullets' => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item
              in (block['items'] as List? ?? []).whereType<String>())
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '•',
                    style: styles.bodyMedium?.copyWith(color: colors.accent),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(item, style: styles.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
      _ => const SizedBox.shrink(),
    };
    return Padding(
      padding: EdgeInsets.only(
        top: kind == 'heading' ? (compact ? 12 : 20) : 6,
      ),
      child: child,
    );
  }
}

class _ReportTable extends StatelessWidget {
  const _ReportTable({required this.block, required this.compact});

  final Map block;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final headers = (block['columns'] as List? ?? [])
        .whereType<String>()
        .toList();
    final rows = (block['rows'] as List? ?? []).whereType<List>().toList();
    if (headers.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = context.clarity;
    final lastIsTotal = block['total'] == true;
    final quickFigures = compact && headers.first == 'Clients';
    final statusChanges = const {'From', 'Time (EAT)'}.contains(headers.first);
    final scale = MediaQuery.textScalerOf(context);

    TableRow row(
      List values, {
      bool header = false,
      bool bold = false,
      bool headline = false,
    }) {
      return TableRow(
        decoration: header ? BoxDecoration(color: colors.accentSoft) : null,
        children: [
          for (var i = 0; i < headers.length; i++)
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 6,
                vertical: compact ? 4 : 7,
              ),
              child: Text(
                i < values.length ? '${values[i]}' : '—',
                textAlign: quickFigures
                    ? TextAlign.center
                    : (i == 0 || statusChanges
                          ? TextAlign.start
                          : TextAlign.end),
                style:
                    Dt.tab(
                      (headline
                          ? theme.textTheme.titleSmall
                          : theme.textTheme.bodySmall)!,
                    ).copyWith(
                      fontWeight: header || bold || headline
                          ? FontWeight.w700
                          : null,
                    ),
              ),
            ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        // At large accessibility sizes, three numeric columns can become
        // narrower than a single currency amount. Keep each metric together.
        if (quickFigures &&
            rows.isNotEmpty &&
            box.maxWidth < scale.scale(260)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, header) in headers.indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(header, style: theme.textTheme.labelMedium),
                      for (final (index, cells) in rows.indexed)
                        if (i < cells.length)
                          Text(
                            '${cells[i]}',
                            style: index == 0
                                ? theme.textTheme.titleMedium
                                : theme.textTheme.bodySmall,
                          ),
                    ],
                  ),
                ),
            ],
          );
        }
        final minWidth = headers.length < 3
            ? 0.0
            : scale.scale(76) * headers.length;
        final table = SizedBox(
          width: math.max(box.maxWidth, minWidth),
          child: Table(
            columnWidths: {
              0: FlexColumnWidth(quickFigures || statusChanges ? 1 : 1.65),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: TableBorder(
              horizontalInside: BorderSide(color: colors.borderSubtle),
            ),
            children: [
              row(headers, header: true),
              for (final (index, cells) in rows.indexed)
                row(
                  cells,
                  bold: lastIsTotal && index == rows.length - 1,
                  headline: quickFigures && index == 0,
                ),
            ],
          ),
        );
        return minWidth > box.maxWidth
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: table,
              )
            : table;
      },
    );
  }
}
