import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'src/app/providers.dart';
import 'src/data/database.dart';
import 'src/data/media_store.dart';
import 'src/data/repository.dart';
import 'src/ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = Repository(AppDatabase.open(), await MediaStore.openDefault());
  runApp(ProviderScope(
    overrides: [repositoryProvider.overrideWithValue(repo)],
    child: const CollectionKeeperApp(),
  ));
}

class CollectionKeeperApp extends StatelessWidget {
  const CollectionKeeperApp({super.key});

  static const _seed = Color(0xFF3B6EA8);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Collection Keeper',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: .fromSeed(seedColor: _seed)),
      darkTheme: ThemeData(colorScheme: .fromSeed(seedColor: _seed, brightness: Brightness.dark)),
      home: const HomeScreen(),
    );
  }
}
