import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/app_provider.dart';
import 'services/audio_service.dart';
import 'services/sync_account_service.dart';
import 'services/sync_pairing.dart';
import 'views/pairing_confirmation.dart';
import 'widgets/adaptive_scaffold.dart';
import 'widgets/sync_scheduler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppProvider()),
        ChangeNotifierProvider(create: (_) => AudioService()),
      ],
      child: const LinguaSrsApp(),
    ),
  );
}

class LinguaSrsApp extends StatefulWidget {
  const LinguaSrsApp({super.key});

  @override
  State<LinguaSrsApp> createState() => _LinguaSrsAppState();
}

class _LinguaSrsAppState extends State<LinguaSrsApp> {
  ThemeMode _themeMode = ThemeMode.system;
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  final _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<Uri>? _uriSubscription;
  String? _lastPairingLink;

  @override
  void initState() {
    super.initState();
    final appLinks = AppLinks();
    _uriSubscription = appLinks.uriLinkStream.listen(
      _handleIncomingUri,
      onError: (Object _) {},
    );
  }

  Future<void> _handleIncomingUri(Uri uri) async {
    if (uri.scheme != SyncPairing.scheme || uri.host != 'pair') return;
    final link = uri.toString();
    if (_lastPairingLink == link) return;
    _lastPairingLink = link;
    try {
      // The dialog needs the navigator, which is not there before the first
      // frame when the app was opened by the link.
      if (_navigatorKey.currentContext == null) {
        await WidgetsBinding.instance.endOfFrame;
      }
      final pairing = await SyncAccountService().redeemPairingLink(link);
      if (!mounted) return;
      final provider = context.read<AppProvider>();
      final dialogContext = _navigatorKey.currentContext;
      if (dialogContext == null || !dialogContext.mounted) return;
      final agreed = await confirmPairing(
        dialogContext,
        pairing,
        replacing: provider.syncPairing,
      );
      if (!agreed) {
        _scaffoldMessengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('Pairing cancelled.')),
        );
        return;
      }
      await provider.setSyncPairing(pairing);
      _scaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Signed in to sync.')),
      );
    } catch (error) {
      _lastPairingLink = null;
      if (!mounted) return;
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Could not use pairing link: $error')),
      );
    }
  }

  @override
  void dispose() {
    _uriSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFF3F51B5); // Indigo accent

    return MaterialApp(
      scaffoldMessengerKey: _scaffoldMessengerKey,
      navigatorKey: _navigatorKey,
      title: 'LinguaSRS - Language Learning Flashcards',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.light,
        ),
        cardTheme: CardThemeData(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.dark,
        ),
        cardTheme: CardThemeData(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
        ),
      ),
      home: Builder(
        builder: (context) {
          final isDark = _isDark(context);
          final provider = context.read<AppProvider>();
          return SyncScheduler(
            changes: provider,
            canSync: () => !provider.isLoading && provider.syncPairing != null,
            hasChanges: () async =>
                (await provider.trackSyncChanges()).isNotEmpty,
            sync: provider.syncNow,
            child: AdaptiveScaffold(
              isDarkMode: isDark,
              onToggleTheme: () => setState(() {
                _themeMode = isDark ? ThemeMode.light : ThemeMode.dark;
              }),
            ),
          );
        },
      ),
    );
  }

  // In system mode, the effective brightness follows the device setting.
  bool _isDark(BuildContext context) => switch (_themeMode) {
    ThemeMode.dark => true,
    ThemeMode.light => false,
    ThemeMode.system =>
      MediaQuery.platformBrightnessOf(context) == Brightness.dark,
  };
}
