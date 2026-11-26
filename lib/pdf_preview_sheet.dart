import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'pdf_import.dart';

const _paper = Color(0xfff7f6f2);
const _ink = Color(0xff1d2320);
const _green = Color(0xff1e6b57);
const _mint = Color(0xffe3efea);
const _stroke = Color(0xffe3e0d8);
const _muted = Color(0xff5d615c);

const int _maxPreviewParagraphs = 50;

sealed class PdfPreviewResult {
  const PdfPreviewResult();
}

final class PdfPreviewConfirm extends PdfPreviewResult {
  const PdfPreviewConfirm(this.title);

  final String title;
}

final class PdfPreviewRepick extends PdfPreviewResult {
  const PdfPreviewRepick();
}

Future<PdfPreviewResult?> showPdfPreviewSheet({
  required BuildContext context,
  required ExtractedPdfDocument document,
  required String locale,
}) {
  final disableAnimations =
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  return showModalBottomSheet<PdfPreviewResult>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    sheetAnimationStyle: disableAnimations
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: Duration(milliseconds: 200),
            reverseDuration: Duration(milliseconds: 180),
          ),
    builder: (context) =>
        _PdfPreviewSheet(document: document, locale: locale),
  );
}

class _PdfPreviewSheet extends StatefulWidget {
  const _PdfPreviewSheet({required this.document, required this.locale});

  final ExtractedPdfDocument document;
  final String locale;

  @override
  State<_PdfPreviewSheet> createState() => _PdfPreviewSheetState();
}

class _PdfPreviewSheetState extends State<_PdfPreviewSheet> {
  late final TextEditingController _titleController;

  bool get _tl => widget.locale == 'tl';
  String _tr(String en, String tl) => _tl ? tl : en;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.document.title);
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  String _formatChars(int count) {
    if (count >= 1000) {
      final compact = (count / 1000).toStringAsFixed(1);
      return '$compact${_tr('k chars', 'k char')}';
    }
    return '$count ${_tr('chars', 'char')}';
  }

  Widget _mintChip(String label) => DecoratedBox(
    decoration: BoxDecoration(
      color: _mint,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Text(
        label,
        style: const TextStyle(
          color: _green,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableHeight = math.max(
      280.0,
      media.size.height - media.viewInsets.bottom,
    );
    final maxSheetHeight = math.min(
      media.size.height * 0.85,
      availableHeight * 0.92,
    );
    final paragraphs = widget.document.paragraphs;
    final visibleCount = math.min(paragraphs.length, _maxPreviewParagraphs);
    final extraCount = paragraphs.length - visibleCount;
    final itemCount = visibleCount + (extraCount > 0 ? 1 : 0);

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 480,
            maxHeight: maxSheetHeight,
          ),
          child: Material(
            color: _paper,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _tr('Check extracted text', 'Suriin ang teksto'),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: _ink,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        tooltip: _tr('Close', 'Isara'),
                        icon: const Icon(Icons.close, color: _ink),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _titleController,
                    builder: (context, value, _) => TextField(
                      controller: _titleController,
                      maxLength: maxLessonTitleLength,
                      maxLines: 1,
                      textInputAction: TextInputAction.done,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                      ),
                      decoration: InputDecoration(
                        labelText: _tr('Lesson title', 'Pamagat ng aralin'),
                        labelStyle: const TextStyle(color: _muted),
                        counterText: '',
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: _stroke),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: _green,
                            width: 1.5,
                          ),
                        ),
                        suffixIcon: value.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: _tr('Clear title', 'Burahin'),
                                onPressed: _titleController.clear,
                                icon: const Icon(
                                  Icons.clear,
                                  size: 18,
                                  color: _muted,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _mintChip(
                          '${widget.document.pageCount} '
                          '${_tr(widget.document.pageCount == 1 ? 'page' : 'pages', 'pahina')}',
                        ),
                        _mintChip('${widget.document.paragraphCount} ¶'),
                        _mintChip(_formatChars(widget.document.charCount)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _stroke),
                      ),
                      child: ListView.separated(
                        padding: const EdgeInsets.all(14),
                        itemCount: itemCount,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 18, color: _stroke),
                        itemBuilder: (context, index) {
                          if (index == visibleCount) {
                            return Center(
                              child: _mintChip(
                                '+$extraCount '
                                '${_tr('more paragraphs included', 'pang talata kasama')}',
                              ),
                            );
                          }
                          final paragraphNumber = index + 1;
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Semantics(
                                label:
                                    '${_tr('Paragraph', 'Talata')} $paragraphNumber',
                                excludeSemantics: true,
                                child: _mintChip('¶$paragraphNumber'),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  paragraphs[index],
                                  style: const TextStyle(
                                    fontSize: 15,
                                    height: 1.45,
                                    color: _ink,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  decoration: const BoxDecoration(
                    color: _paper,
                    border: Border(top: BorderSide(color: _stroke)),
                  ),
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _titleController,
                    builder: (context, value, _) {
                      final trimmed = value.text.trim();
                      final canCreate = trimmed.isNotEmpty;
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Semantics(
                            button: true,
                            enabled: canCreate,
                            hint: canCreate
                                ? null
                                : _tr(
                                    'Enter a lesson title first',
                                    'Maglagay muna ng pamagat ng aralin',
                                  ),
                            child: SizedBox(
                              width: double.infinity,
                              child: OutlinedButton(
                                onPressed: canCreate
                                    ? () => Navigator.pop(
                                        context,
                                        PdfPreviewConfirm(trimmed),
                                      )
                                    : null,
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: _green,
                                  foregroundColor: Colors.white,
                                  disabledBackgroundColor: _stroke,
                                  disabledForegroundColor: _muted,
                                  side: BorderSide(
                                    color: canCreate ? _green : _stroke,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                    horizontal: 12,
                                  ),
                                  minimumSize: const Size(0, 50),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  textStyle: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    _tr(
                                      'Create study pack',
                                      'Gumawa ng study pack',
                                    ),
                                    maxLines: 1,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(
                                context,
                                const PdfPreviewRepick(),
                              ),
                              style: OutlinedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: _green,
                                side: const BorderSide(color: _green),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                  horizontal: 12,
                                ),
                                minimumSize: const Size(0, 50),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _tr(
                                    'Choose another PDF',
                                    'Pumili ng ibang PDF',
                                  ),
                                  maxLines: 1,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
