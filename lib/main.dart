import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller.dart';
import 'ui/workspace.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: InsightsApp()));
}

class InsightsApp extends ConsumerWidget {
  const InsightsApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appProvider);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        ThemeData theme(Brightness brightness) {
          final colors = ColorScheme.fromSeed(
            seedColor: const Color(0xff087f78),
            brightness: brightness,
          );
          return ThemeData(
            useMaterial3: true,
            colorScheme: colors,
            brightness: brightness,
            scaffoldBackgroundColor: brightness == Brightness.light
                ? const Color(0xfff6f7f9)
                : const Color(0xff14191d),
            visualDensity: VisualDensity.standard,
            inputDecorationTheme: const InputDecorationTheme(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            appBarTheme: const AppBarTheme(
              elevation: 0,
              scrolledUnderElevation: 0,
            ),
            dividerTheme: DividerThemeData(
              color: colors.outlineVariant.withValues(alpha: .6),
              space: 1,
            ),
            textTheme: const TextTheme(
              headlineMedium: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
              ),
              titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
          );
        }

        return MaterialApp(
          title: 'Serverpod Insights Linux',
          debugShowCheckedModeBanner: false,
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: theme(Brightness.light),
          darkTheme: theme(Brightness.dark),
          themeMode: app.dark ? ThemeMode.dark : ThemeMode.light,
          home: Workspace(app: app),
        );
      },
    );
  }
}
