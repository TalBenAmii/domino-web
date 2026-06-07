import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

void main() => runApp(const DominoApp());

/// Root of the app. A single screen, Material 3, laid out right-to-left for
/// Hebrew. The whole UI is wrapped in an RTL [Directionality] so Material
/// widgets (AppBar actions, text alignment, etc.) flow naturally for Hebrew
/// without pulling in the flutter_localizations delegates.
class DominoApp extends StatelessWidget {
  const DominoApp({super.key});

  static const Color _seed = Color(0xFF6C4DF6); // violet

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'דיבור לטקסט',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: SpeechScreen(),
      ),
    );
  }
}

class SpeechScreen extends StatefulWidget {
  const SpeechScreen({super.key});

  @override
  State<SpeechScreen> createState() => _SpeechScreenState();
}

class _SpeechScreenState extends State<SpeechScreen>
    with SingleTickerProviderStateMixin {
  final SpeechToText _speech = SpeechToText();
  final ScrollController _scroll = ScrollController();
  late final AnimationController _pulse;

  bool _initializing = true; // resolving recognizer availability
  bool _available = false; // recognizer is usable on this device
  bool _isListening = false; // a listen session is active
  String _finalText = ''; // accumulated, committed transcript
  String _partialText = ''; // live in-progress words for current utterance
  String? _errorMsg; // last error message, if any
  String? _localeId; // resolved Hebrew locale id (device dependent)

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _initSpeech();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _scroll.dispose();
    _speech.cancel();
    super.dispose();
  }

  /// Initialize the recognizer (this also triggers the OS microphone /
  /// speech-recognition permission prompts) and resolve the Hebrew locale.
  Future<void> _initSpeech() async {
    bool available = false;
    try {
      available = await _speech.initialize(
        onStatus: _onStatus,
        onError: _onError,
      );
      if (available) {
        final locales = await _speech.locales();
        // Device locale ids vary: he_IL, he-IL, or the legacy iw_IL. Match a
        // prefix instead of hardcoding a single string.
        final hebrew = locales.where((l) {
          final id = l.localeId.toLowerCase();
          return id.startsWith('he') || id.startsWith('iw');
        }).toList();
        _localeId = hebrew.isNotEmpty ? hebrew.first.localeId : 'he_IL';
      }
    } catch (e) {
      available = false;
      _errorMsg = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _available = available;
      _initializing = false;
    });
  }

  void _onStatus(String status) {
    if (!mounted) return;
    final listening = status == SpeechToText.listeningStatus;
    setState(() {
      _isListening = listening;
      // When a session ends, fold any trailing partial words into the final
      // transcript so nothing is lost.
      if (!listening && _partialText.isNotEmpty) {
        _finalText = _merge(_finalText, _partialText);
        _partialText = '';
      }
    });
  }

  void _onError(SpeechRecognitionError error) {
    if (!mounted) return;
    setState(() {
      _isListening = false;
      _errorMsg = error.errorMsg;
    });
  }

  void _onResult(SpeechRecognitionResult result) {
    if (!mounted) return;
    setState(() {
      if (result.finalResult) {
        _finalText = _merge(_finalText, result.recognizedWords);
        _partialText = '';
      } else {
        _partialText = result.recognizedWords;
      }
    });
    _autoScroll();
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speech.stop(); // graceful stop; flushes a final result
      if (mounted) setState(() => _isListening = false);
      return;
    }

    // Recover if a previous init failed (e.g. permission was just granted).
    if (!_available) {
      await _initSpeech();
      if (!_available) return;
    }

    setState(() {
      _errorMsg = null;
      _partialText = '';
      _isListening = true;
    });

    await _speech.listen(
      onResult: _onResult,
      listenOptions: SpeechListenOptions(
        localeId: _localeId,
        partialResults: true, // live, word-by-word display
        cancelOnError: false,
        listenMode: ListenMode.dictation, // continuous speech, not commands
        onDevice: false, // cloud/online recognition is fine for v1
        autoPunctuation: true, // iOS only; harmless on Android
        listenFor: const Duration(minutes: 5), // hard session cap
        pauseFor: const Duration(seconds: 6), // auto-stop after silence
      ),
    );
  }

  String _merge(String a, String b) {
    final left = a.trim();
    final right = b.trim();
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;
    return '$left $right';
  }

  String get _displayText => _merge(_finalText, _partialText);
  bool get _hasText => _finalText.isNotEmpty || _partialText.isNotEmpty;

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _clear() {
    setState(() {
      _finalText = '';
      _partialText = '';
      _errorMsg = null;
    });
  }

  Future<void> _copy() async {
    final text = _displayText;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('הטקסט הועתק ללוח')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('דיבור לטקסט'),
        actions: [
          if (_hasText) ...[
            IconButton(
              onPressed: _copy,
              icon: const Icon(Icons.copy_rounded),
              tooltip: 'העתק',
            ),
            IconButton(
              onPressed: _clear,
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: 'נקה',
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            children: [
              Expanded(child: _buildTranscript(theme)),
              const SizedBox(height: 12),
              _buildStatus(theme),
              const SizedBox(height: 16),
              _buildMicButton(theme),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTranscript(ThemeData theme) {
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: _hasText
          ? SingleChildScrollView(
              controller: _scroll,
              child: RichText(
                textAlign: TextAlign.right,
                textDirection: TextDirection.rtl,
                text: TextSpan(
                  style: theme.textTheme.headlineSmall?.copyWith(
                    height: 1.5,
                    color: cs.onSurface,
                  ),
                  children: [
                    TextSpan(text: _finalText),
                    if (_partialText.isNotEmpty)
                      TextSpan(
                        text: '${_finalText.isEmpty ? '' : ' '}$_partialText',
                        style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                  ],
                ),
              ),
            )
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.record_voice_over_outlined,
                    size: 64,
                    color: cs.outline.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'הטקסט שלך יופיע כאן',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: cs.outline,
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildStatus(ThemeData theme) {
    final cs = theme.colorScheme;
    String text;
    Color color;
    if (_initializing) {
      text = 'מאתחל זיהוי דיבור...';
      color = cs.outline;
    } else if (!_available) {
      text = 'זיהוי דיבור אינו זמין במכשיר זה';
      color = cs.error;
    } else if (_errorMsg != null) {
      text = 'שגיאה: $_errorMsg';
      color = cs.error;
    } else if (_isListening) {
      text = 'מקשיב...';
      color = cs.primary;
    } else {
      text = 'הקש על המיקרופון כדי להתחיל';
      color = cs.outline;
    }
    return Text(
      text,
      textAlign: TextAlign.center,
      style: theme.textTheme.titleMedium?.copyWith(color: color),
    );
  }

  Widget _buildMicButton(ThemeData theme) {
    final cs = theme.colorScheme;
    final enabled = _available && !_initializing;
    final accent = _isListening ? cs.error : cs.primary;

    return GestureDetector(
      onTap: enabled ? _toggleListening : null,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final t = _pulse.value; // 0..1
          return SizedBox(
            width: 170,
            height: 170,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (_isListening) ...[
                  _halo(cs.error, 100 + t * 60, (1 - t) * 0.25),
                  _halo(cs.error, 100 + t * 30, (1 - t) * 0.40),
                ],
                child!,
              ],
            ),
          );
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _isListening
                  ? [cs.error, cs.error.withValues(alpha: 0.7)]
                  : enabled
                      ? [cs.primary, cs.primaryContainer]
                      : [
                          cs.surfaceContainerHighest,
                          cs.surfaceContainerHighest,
                        ],
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: enabled ? 0.4 : 0.0),
                blurRadius: 24,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Icon(
            _isListening ? Icons.stop_rounded : Icons.mic_rounded,
            size: 46,
            color: enabled ? Colors.white : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _halo(Color color, double size, double opacity) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: opacity.clamp(0.0, 1.0)),
      ),
    );
  }
}
