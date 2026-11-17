import '../../core/utilities/units.dart';
import '../../simulation/model/config.dart';

class AppSettings {
  AppSettings({
    required this.geometryUnit,
    required this.lengthUnit,
    required this.defaultStackup,
    required this.thresholds,
  });

  GeometryUnit geometryUnit;
  LengthUnit lengthUnit;
  StackupConfig defaultStackup;
  SiThresholds thresholds;

  factory AppSettings.defaults() => AppSettings(
        geometryUnit: GeometryUnit.mil,
        lengthUnit: LengthUnit.mm,
        defaultStackup: StackupConfig.preset(4),
        thresholds: SiThresholds(),
      );

  AppSettings copy() => AppSettings.fromJson(toJson());

  Map<String, Object?> toJson() => {
        'geometryUnit': geometryUnit.name,
        'lengthUnit': lengthUnit.name,
        'stackup': defaultStackup.toJson(),
        'thresholds': thresholds.toJson(),
      };

  factory AppSettings.fromJson(Map<String, Object?> j) {
    final d = AppSettings.defaults();
    return AppSettings(
      geometryUnit: GeometryUnit.values.firstWhere((u) => u.name == j['geometryUnit'],
          orElse: () => d.geometryUnit),
      lengthUnit:
          LengthUnit.values.firstWhere((u) => u.name == j['lengthUnit'], orElse: () => d.lengthUnit),
      defaultStackup: j['stackup'] is Map
          ? StackupConfig.fromJson((j['stackup'] as Map).cast<String, Object?>())
          : d.defaultStackup,
      thresholds: j['thresholds'] is Map
          ? SiThresholds.fromJson((j['thresholds'] as Map).cast<String, Object?>())
          : d.thresholds,
    );
  }
}
