import '../data/local_database/app_database.dart';
import '../data/repositories/analysis_repository.dart';
import '../data/repositories/sqlite_repository.dart';

/// Where analyses are kept on this platform (shown in About).
const String storageDescription = 'on this device (local database)';

Future<AnalysisRepository> createPlatformRepository() async => SqliteAnalysisRepository(await AppDatabase.open());
