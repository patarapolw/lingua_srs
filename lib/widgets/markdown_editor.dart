import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_all/webview_all.dart';

import '../services/html_to_markdown.dart';
import 'lesson_content_view.dart';

/// A Markdown editor with an Edit / Preview switch.
///
/// Editing happens in a `<textarea>` in a WebView ([MarkdownEditorHtml]), so
/// the browser lays out the text, CJK fallback fonts included, and pasted
/// HTML (a web page, a Google Docs selection) is converted to Markdown from
/// the paste event itself. Preview shows the text as the lesson reader does
/// ([LessonContentView]).
///
/// The WebView is not started while the text is empty and the person has
/// not chosen to write yet: a placeholder stands in for it. Edit and
/// Preview each start their WebView the first time they are shown and keep
/// it, hidden, while the other is shown. Without a WebView platform (widget
/// tests), [fallback] is shown instead.
class MarkdownEditor extends StatefulWidget {
  /// Holds the text. Changes made to it in code are shown in the editor.
  final TextEditingController controller;

  /// Shown where there is no WebView, instead of the editor and preview.
  final Widget fallback;
  final bool enabled;

  /// Shown in the empty editor, and in the placeholder before it starts.
  final String? hintText;

  /// Called with the text after each edit made in the editor, not for
  /// changes made to [controller] in code.
  final ValueChanged<String>? onChanged;

  /// Called for Ctrl/Cmd+S or Ctrl/Cmd+Enter in the editor.
  final VoidCallback? onSave;

  /// Whether to open in Preview when there is text.
  final bool startInPreview;

  /// Whether to offer Preview at all (not for YAML).
  final bool allowPreview;

  /// The Markdown Preview shows for the text, such as the text without its
  /// frontmatter. The text itself when null.
  final String Function(String text)? previewMarkdown;

  const MarkdownEditor({
    super.key,
    required this.controller,
    required this.fallback,
    this.enabled = true,
    this.hintText,
    this.onChanged,
    this.onSave,
    this.startInPreview = false,
    this.allowPreview = true,
    this.previewMarkdown,
  });

  /// Overrides whether a WebView is used, for tests. When null, it is used
  /// wherever a WebView platform is registered.
  @visibleForTesting
  static bool? debugUseWebView;

  static bool get _useWebView =>
      debugUseWebView ?? WebViewPlatform.instance != null;

  @override
  State<MarkdownEditor> createState() => _MarkdownEditorState();
}

class _MarkdownEditorState extends State<MarkdownEditor> {
  /// Whether the person chose to write (or there was text), so the WebView
  /// editor is shown rather than the placeholder.
  late bool _started = widget.controller.text.isNotEmpty;
  late bool _preview =
      widget.allowPreview &&
      widget.startInPreview &&
      widget.controller.text.trim().isNotEmpty;

  /// Counts the times the person chose to write (a tap on the placeholder,
  /// or Edit); the editor takes focus on each.
  int _focusRequest = 0;

  /// What Preview shows: the Markdown as it was when Preview was last
  /// chosen, kept up to date while it is shown. Null until Preview is first
  /// shown, so its WebView starts only then.
  String? _previewText;

  /// Whether the editor has been shown, so its WebView is kept from then on.
  bool _editorShown = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    if (_preview) _previewText = _previewOf(widget.controller.text);
  }

  String _previewOf(String text) => widget.previewMarkdown?.call(text) ?? text;

  @override
  void didUpdateWidget(MarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
    }
    if (!widget.allowPreview && _preview) _preview = false;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  /// Text put in the controller in code (a file read, say) starts the
  /// editor, and is shown in Preview if Preview is shown.
  void _onText() {
    if (!mounted) return;
    final text = widget.controller.text;
    final start = !_started && text.isNotEmpty;
    if (!start && !_preview) return;
    setState(() {
      if (start) _started = true;
      if (_preview) _previewText = _previewOf(text);
    });
  }

  void _setPreview(bool preview) {
    if (preview == _preview) return;
    setState(() {
      _preview = preview;
      if (preview) {
        _previewText = _previewOf(widget.controller.text);
      } else {
        // Choosing Edit is choosing to write, even with no text yet.
        _started = true;
        _focusRequest++;
      }
    });
  }

  void _start() {
    setState(() {
      _started = true;
      _focusRequest++;
    });
  }

  /// Keeps [child] (and its WebView) while another view is shown.
  static Widget _layer({
    required Key key,
    required bool visible,
    required Widget child,
  }) => Visibility(
    key: key,
    visible: visible,
    maintainState: true,
    child: ExcludeFocus(excluding: !visible, child: child),
  );

  @override
  Widget build(BuildContext context) {
    if (!MarkdownEditor._useWebView) return widget.fallback;
    final previewText = _previewText;
    // The editor's WebView starts the first time Edit is shown with text
    // (or once asked to write), not while the page opens on Preview.
    if (_started && !_preview) _editorShown = true;
    final body = Stack(
      fit: StackFit.expand,
      children: [
        if (_editorShown)
          _layer(
            key: const ValueKey('editor'),
            visible: !_preview,
            child: MarkdownWebEditor(
              controller: widget.controller,
              enabled: widget.enabled,
              hintText: widget.hintText,
              focusRequest: _focusRequest,
              onChanged: widget.onChanged,
              onSave: widget.onSave,
            ),
          )
        else if (!_started && !_preview)
          _EditorPlaceholder(
            key: const ValueKey('placeholder'),
            hintText: widget.hintText,
            onTap: widget.enabled ? _start : null,
          ),
        if (previewText != null)
          _layer(
            key: const ValueKey('preview'),
            visible: _preview,
            child: _MarkdownPreview(markdown: previewText),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.allowPreview) ...[
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.edit_outlined),
                  label: Text('Edit'),
                  tooltip: 'Edit the Markdown',
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.visibility_outlined),
                  label: Text('Preview'),
                  tooltip: 'Preview the lesson text',
                ),
              ],
              selected: {_preview},
              onSelectionChanged: (selected) => _setPreview(selected.first),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(child: body),
      ],
    );
  }
}

/// Stands in for the editor until the person chooses to write, so an empty
/// text starts no WebView.
class _EditorPlaceholder extends StatelessWidget {
  final String? hintText;
  final VoidCallback? onTap;

  const _EditorPlaceholder({
    super.key,
    required this.hintText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      label: 'Write Markdown',
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: scheme.outline),
          borderRadius: BorderRadius.circular(4),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('markdown-editor-placeholder'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.edit_note, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Tap to write Markdown',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
                if (hintText case final hint?) ...[
                  const SizedBox(height: 12),
                  Expanded(
                    child: ClipRect(
                      child: Text(
                        hint,
                        softWrap: true,
                        overflow: TextOverflow.fade,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant.withValues(
                            alpha: 0.65,
                          ),
                          fontFamily: 'monospace',
                          fontSize: 14,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The text as the lesson reader shows it.
class _MarkdownPreview extends StatelessWidget {
  final String markdown;

  const _MarkdownPreview({required this.markdown});

  @override
  Widget build(BuildContext context) {
    if (markdown.trim().isEmpty) {
      return Center(
        child: Text(
          'Nothing to preview yet.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: LessonContentView(markdown: markdown),
      ),
    );
  }
}

/// A `<textarea>` in a WebView that edits [controller]'s text.
class MarkdownWebEditor extends StatefulWidget {
  final TextEditingController controller;
  final bool enabled;
  final String? hintText;

  /// The editor takes focus when this is above 0 as it loads, and again
  /// each time it goes up.
  final int focusRequest;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSave;

  const MarkdownWebEditor({
    super.key,
    required this.controller,
    this.enabled = true,
    this.hintText,
    this.focusRequest = 0,
    this.onChanged,
    this.onSave,
  });

  @override
  State<MarkdownWebEditor> createState() => _MarkdownWebEditorState();
}

class _MarkdownWebEditorState extends State<MarkdownWebEditor> {
  // As in LessonContentView: on Windows the page is injected into a bundled
  // asset rather than loaded from a string.
  static const _windowsHostAsset = 'assets/webview_host.html';

  static bool get _useWindowsHostAsset =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  final WebViewController _web = WebViewController();
  late final Future<void> _configured = _configure();

  /// The text the page holds, as far as the app knows: what it was loaded
  /// with or last sent, or what it last reported.
  String? _pageText;
  String? _shownCss;
  bool _loading = true;
  bool _loaded = false;
  String? _injection;

  /// Whether the textarea has focus, for the border drawn around it.
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(MarkdownWebEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _onControllerChanged();
    }
    if (oldWidget.enabled != widget.enabled && _loaded) {
      _web.runJavaScript(MarkdownEditorHtml.setDisabled(!widget.enabled));
    }
    if (widget.focusRequest > oldWidget.focusRequest && _loaded) _focus();
  }

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const _androidChannel = MethodChannel('lingua/markdown_editor');

  /// The page's title, which the Android side finds this WebView by.
  late final String _title = 'lingua-editor-${identityHashCode(this)}';

  /// Puts the focus in the editor, with the keyboard up on Android.
  Future<void> _focus() async {
    if (_isAndroid) {
      // A JavaScript focus() alone opens no keyboard there: the WebView
      // has no native focus until it is touched.
      try {
        final focused = await _androidChannel.invokeMethod<bool>('focus', {
          'title': _title,
          'script': MarkdownEditorHtml.focus,
        });
        if (focused == true) return;
      } on PlatformException {
        // Below, as on other platforms.
      } on MissingPluginException {
        // Below, as on other platforms.
      }
      if (!mounted) return;
    }
    _web.runJavaScript(MarkdownEditorHtml.focus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _show();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    releaseWebView(_web);
    super.dispose();
  }

  Future<void> _configure() async {
    await _web.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _web.addJavaScriptChannel('Lingua', onMessageReceived: _onMessage);
    await _web.setNavigationDelegate(
      NavigationDelegate(
        // Only the editor page itself loads: a link or file dropped on it
        // does not navigate away.
        onNavigationRequest: (request) => _loading && request.isMainFrame
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
        onPageFinished: (_) => _onPageFinished(),
      ),
    );
  }

  String _css() {
    final theme = Theme.of(context);
    final fontSize = MediaQuery.textScalerOf(context).scale(14);
    return MarkdownEditorHtml.css(theme, fontSize: fontSize);
  }

  /// Loads the editor page the first time; afterwards only restyles it.
  Future<void> _show() async {
    final css = _css();
    final background = Theme.of(context).colorScheme.surface;
    await _configured;
    if (!mounted || css == _shownCss) return;
    if (_shownCss != null) {
      // While the page loads, [_onPageFinished] restyles it.
      if (_loaded) {
        _shownCss = css;
        _web.runJavaScript(MarkdownEditorHtml.setCss(css));
      }
      return;
    }
    _shownCss = css;
    final value = widget.controller.value;
    final text = value.text;
    final selection = value.selection;
    final start = MarkdownEditorHtml.start(
      text: text,
      placeholder: widget.hintText ?? '',
      disabled: !widget.enabled,
      focus: widget.focusRequest > 0,
      selectionStart: selection.isValid ? selection.start : 0,
      selectionEnd: selection.isValid ? selection.end : 0,
    );
    _pageText = text;
    _loading = true;
    try {
      await _web.setBackgroundColor(background);
    } catch (_) {}
    if (_useWindowsHostAsset) {
      _injection = MarkdownEditorHtml.injection(css, start: start);
      await _web.loadFlutterAsset(_windowsHostAsset);
    } else {
      await _web.loadHtmlString(
        MarkdownEditorHtml.page(css, start: start, title: _title),
      );
    }
  }

  void _onPageFinished() {
    if (!mounted) return;
    final injection = _injection;
    _injection = null;
    if (injection != null) _web.runJavaScript(injection);
    _loading = false;
    _loaded = true;
    // A new theme, or text set in code, while the page loaded.
    final css = _css();
    if (css != _shownCss) {
      _shownCss = css;
      _web.runJavaScript(MarkdownEditorHtml.setCss(css));
    }
    _onControllerChanged();
    // The start script focused the textarea, but that opens no keyboard on
    // Android.
    if (widget.focusRequest > 0 && _isAndroid) _focus();
  }

  /// Sends text put in the controller in code to the page.
  void _onControllerChanged() {
    // Until the page loads, [_onPageFinished] sends what changed.
    if (!_loaded) return;
    final text = widget.controller.text;
    if (text == _pageText) return;
    _pageText = text;
    _web.runJavaScript(MarkdownEditorHtml.setText(text));
  }

  void _onMessage(JavaScriptMessage message) {
    if (!mounted) return;
    final Object? data;
    try {
      data = jsonDecode(message.message);
    } on FormatException {
      return;
    }
    if (data is! Map) return;
    switch (data['type']) {
      case 'change':
        final text = data['text'];
        if (text is! String) return;
        _pageText = text;
        final end = _offset(data['end'], text);
        final start = _offset(data['start'], text) ?? end;
        widget.controller.value = TextEditingValue(
          text: text,
          selection: end == null
              ? TextSelection.collapsed(offset: text.length)
              : TextSelection(baseOffset: start!, extentOffset: end),
        );
        widget.onChanged?.call(text);
      case 'paste':
        final html = data['html'];
        final plain = data['text'];
        final pasted = MarkdownEditorHtml.pastedText(
          html is String ? html : '',
          plain is String ? plain : '',
        );
        if (pasted.isEmpty) return;
        final start = data['start'];
        final end = data['end'];
        if (start is! int || end is! int) return;
        _web.runJavaScript(MarkdownEditorHtml.insert(start, end, pasted));
      case 'save':
        widget.onSave?.call();
      case 'focus':
        final focused = data['focused'] == true;
        if (focused != _focused) setState(() => _focused = focused);
    }
  }

  static int? _offset(Object? value, String text) =>
      value is int ? value.clamp(0, text.length) : null;

  // The border is drawn here, not by the page: the WebView's viewport can be
  // a few pixels larger than the widget, which cut off the right and bottom
  // of a border drawn on the textarea.
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(
          color: _focused ? scheme.primary : scheme.outline,
          width: _focused ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        // As wide as the focused border, so focus does not resize the page.
        padding: const EdgeInsets.all(2),
        child: WebViewWidget(
          controller: _web,
          // Every touch goes to the editor. Otherwise a parent that also
          // takes drags (the Add Lessons tabs on a phone) holds the touch
          // in the gesture arena, and Android's long press for the
          // copy/paste menu never reaches the WebView.
          gestureRecognizers: {
            Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
          },
        ),
      ),
    );
  }
}

/// The page [MarkdownWebEditor] shows: a `<textarea>` and the script that
/// reports its edits, pastes and save shortcuts through the `Lingua`
/// channel.
abstract final class MarkdownEditorHtml {
  /// What a paste of [html] (with [plain], its plain text) puts in the
  /// editor: the HTML as Markdown when it has formatting, otherwise the
  /// plain text.
  static String pastedText(String html, String plain) {
    if (html.trim().isNotEmpty) {
      final markdown = htmlToMarkdown(html);
      if (markdown != null) return markdown;
    }
    return plain;
  }

  /// The CSS of the page, from the app's [theme]. [fontSize] is the text
  /// size in logical pixels (the user's text scale applied).
  static String css(ThemeData theme, {double fontSize = 14}) {
    String hex(Color c) =>
        '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    final scheme = theme.colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return '''
:root { color-scheme: ${dark ? 'dark' : 'light'}; }
html, body { margin: 0; height: 100%; background: ${hex(scheme.surface)}; }
textarea { box-sizing: border-box; display: block; width: 100%; height: 100%; margin: 0; padding: 10px 14px; resize: none; outline: none; border: none; background: ${hex(scheme.surface)}; color: ${hex(scheme.onSurface)}; caret-color: ${hex(scheme.primary)}; font: ${fontSize.toStringAsFixed(1)}px/1.45 ui-monospace, "SF Mono", Menlo, Consolas, "Noto Sans Mono", "Noto Sans Mono CJK KR", monospace; tab-size: 2; white-space: pre-wrap; overflow-wrap: anywhere; -webkit-text-size-adjust: 100%; }
textarea::placeholder { color: ${hex(scheme.onSurfaceVariant)}; opacity: 0.65; }
textarea:disabled { opacity: 0.6; }
''';
  }

  /// Defines the `linguaEditor…` functions and reports edits, HTML pastes
  /// and Ctrl/Cmd+S or Ctrl/Cmd+Enter to the app.
  static const script = r'''
(function () {
  var ta = document.getElementById('editor');
  function post(message) {
    if (window.Lingua) window.Lingua.postMessage(JSON.stringify(message));
  }
  function changed() {
    post({type: 'change', text: ta.value, start: ta.selectionStart, end: ta.selectionEnd});
  }
  window.linguaEditorStart = function (text, placeholder, disabled, focus, start, end) {
    ta.value = text;
    ta.placeholder = placeholder;
    ta.disabled = disabled;
    ta.setSelectionRange(Math.min(start, text.length), Math.min(end, text.length));
    if (focus) ta.focus();
  };
  window.linguaEditorSetText = function (text) {
    if (ta.value === text) return;
    var start = ta.selectionStart, end = ta.selectionEnd;
    ta.value = text;
    ta.setSelectionRange(Math.min(start, text.length), Math.min(end, text.length));
  };
  window.linguaEditorSetDisabled = function (disabled) { ta.disabled = disabled; };
  window.linguaEditorSetCss = function (css) {
    document.getElementById('lingua-editor-style').textContent = css;
  };
  window.linguaEditorInsert = function (start, end, text) {
    ta.focus();
    ta.setSelectionRange(start, end);
    var done = false;
    // Keeps the browser's undo history; fires the input event itself.
    try { done = document.execCommand('insertText', false, text); } catch (e) {}
    if (!done) {
      ta.setRangeText(text, start, end, 'end');
      changed();
    }
  };
  window.linguaEditorFocus = function () { ta.focus(); };
  ta.addEventListener('focus', function () { post({type: 'focus', focused: true}); });
  ta.addEventListener('blur', function () { post({type: 'focus', focused: false}); });
  ta.addEventListener('input', changed);
  ta.addEventListener('paste', function (e) {
    var data = e.clipboardData;
    if (!data) return;
    var html = data.getData('text/html');
    if (!html) return;
    e.preventDefault();
    post({type: 'paste', html: html, text: data.getData('text/plain'),
      start: ta.selectionStart, end: ta.selectionEnd});
  });
  ta.addEventListener('keydown', function (e) {
    if ((e.ctrlKey || e.metaKey) && !e.altKey &&
        (e.key === 's' || e.key === 'S' || e.key === 'Enter')) {
      e.preventDefault();
      post({type: 'save'});
    }
  });
})();
''';

  static String _json(Object? value) =>
      jsonEncode(value).replaceAll('<', r'\u003c');

  /// The call that fills the editor when the page starts.
  static String start({
    required String text,
    String placeholder = '',
    bool disabled = false,
    bool focus = false,
    int selectionStart = 0,
    int selectionEnd = 0,
  }) =>
      'linguaEditorStart(${_json(text)}, ${_json(placeholder)}, '
      '${_json(disabled)}, ${_json(focus)}, ${_json(selectionStart)}, '
      '${_json(selectionEnd)});';

  /// Replaces the editor's text with [text], made in the app.
  static String setText(String text) => 'linguaEditorSetText(${_json(text)});';

  static String setDisabled(bool disabled) =>
      'linguaEditorSetDisabled(${_json(disabled)});';

  /// Puts the focus in the editor.
  static const focus = 'linguaEditorFocus();';

  static String setCss(String css) => 'linguaEditorSetCss(${_json(css)});';

  /// Puts [text] in place of the editor's text from [start] to [end].
  static String insert(int start, int end, String text) =>
      'linguaEditorInsert(${_json(start)}, ${_json(end)}, ${_json(text)});';

  /// What goes inside `<html>`: the head, with [css], and the textarea.
  static String inner(String css) =>
      '<head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style id="lingua-editor-style">$css</style></head>'
      '<body><textarea id="editor" spellcheck="false" autocomplete="off" '
      'autocapitalize="off" aria-label="Markdown"></textarea>';

  /// A whole page, for a WebView that can load an HTML string. [title]
  /// (letters, digits and `-`) tells this editor's WebView apart on
  /// Android.
  static String page(String css, {String start = '', String title = ''}) =>
      '<!DOCTYPE html><html>'
      '${inner(css).replaceFirst('<head>', '<head><title>$title</title>')}'
      '<script>$script\n$start</script></body></html>';

  /// A script that replaces the WebView's page with the editor, for
  /// platforms that load a bundled asset instead of an HTML string.
  static String injection(String css, {String start = ''}) =>
      'document.documentElement.innerHTML = ${_json('${inner(css)}</body>')};\n'
      '$script\n$start';
}
