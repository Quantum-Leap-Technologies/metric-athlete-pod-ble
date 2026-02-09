/// Comprehensive session analytics model matching the `session_data` database table.
///
/// Contains all computed metrics from a GPS/IMU session including distances,
/// speeds, zone breakdowns, impacts, player load, and data quality indicators.
class SessionStats {
  // --- Distance Metrics ---
  final double totalDistanceKm;
  final double activeDistanceKm;
  final double distancePerMin;
  final double sprintDistance;
  final double hsrDistance; // High-Speed Running distance
  final double explosiveDistance;

  // --- Speed Metrics ---
  final double topSpeedKmh;
  final double avgSpeedKmh;
  final int sprintCount;

  // --- Acceleration Metrics ---
  final int accelerationCount;
  final int decelerationCount;
  final double maxAcceleration; // peak acceleration in m/s²

  // --- Impact Metrics ---
  final int impactCount;
  final double maxImpactG;
  final int hieCount; // High-Intensity Events

  // --- Load Metrics ---
  final double playerLoad;
  final double loadScore;
  final double sessionIntensity;
  final double fatigueIndex;

  // --- HSR & Distance Metrics ---
  final int hsrEfforts; // rising-edge count of speed crossing HSR threshold
  final double distanceToMaxSpeedM; // cumulative distance when top speed occurred

  // --- Weight-Dependent Metabolic Metrics ---
  final double hmldDistanceM; // High Metabolic Load Distance in meters
  final double hmldPercentage; // HMLD as % of total distance
  final double hmldPerMin; // HMLD per minute
  final double momentumPeak; // peak momentum = weight * max speed (kg·m/s)
  final double energyKcal; // estimated energy expenditure
  final int powerPlayCount; // rising-edge count of metabolic power > 25.5 W/kg

  // --- Personal Best Metrics ---
  final double personalMaxPercentage; // top speed as % of personal best
  final bool above90PercentMax; // whether top speed >= 90% of personal best

  // --- Data Quality ---
  final double gpsQualityPercentage;
  final int dataGapsCount;
  final int durationSeconds;

  // --- Zone Breakdowns ---
  /// Distance per zone in km: {'Resting': 0.1, 'Walking': 1.2, ...}
  final Map<String, double> zoneDistances;

  /// Impact counts per zone: {'Running': 5, 'Sprinting': 3, ...}
  final Map<String, int> impactCountsByZone;

  /// Time spent in each zone in seconds: {'Resting': 120, 'Walking': 300, ...}
  final Map<String, int> zoneTimeSeconds;

  const SessionStats({
    this.totalDistanceKm = 0,
    this.activeDistanceKm = 0,
    this.distancePerMin = 0,
    this.sprintDistance = 0,
    this.hsrDistance = 0,
    this.explosiveDistance = 0,
    this.topSpeedKmh = 0,
    this.avgSpeedKmh = 0,
    this.sprintCount = 0,
    this.accelerationCount = 0,
    this.decelerationCount = 0,
    this.maxAcceleration = 0,
    this.impactCount = 0,
    this.maxImpactG = 0,
    this.hieCount = 0,
    this.playerLoad = 0,
    this.loadScore = 0,
    this.sessionIntensity = 0,
    this.fatigueIndex = 0,
    this.hsrEfforts = 0,
    this.distanceToMaxSpeedM = 0,
    this.hmldDistanceM = 0,
    this.hmldPercentage = 0,
    this.hmldPerMin = 0,
    this.momentumPeak = 0,
    this.energyKcal = 0,
    this.powerPlayCount = 0,
    this.personalMaxPercentage = 0,
    this.above90PercentMax = false,
    this.gpsQualityPercentage = 0,
    this.dataGapsCount = 0,
    this.durationSeconds = 0,
    this.zoneDistances = const {},
    this.impactCountsByZone = const {},
    this.zoneTimeSeconds = const {},
  });

  /// Creates a SessionStats from a map (e.g., from GraphQL response).
  factory SessionStats.fromMap(Map<String, dynamic> map) {
    return SessionStats(
      totalDistanceKm: (map['total_distance'] as num?)?.toDouble() ?? 0,
      activeDistanceKm: (map['active_distance'] as num?)?.toDouble() ?? 0,
      distancePerMin: (map['distance_per_min'] as num?)?.toDouble() ?? 0,
      sprintDistance: (map['sprint_distance'] as num?)?.toDouble() ?? 0,
      hsrDistance: (map['hsr_distance'] as num?)?.toDouble() ?? 0,
      explosiveDistance: (map['explosive_distance'] as num?)?.toDouble() ?? 0,
      topSpeedKmh: (map['max_speed'] as num?)?.toDouble() ?? 0,
      avgSpeedKmh: (map['avg_speed'] as num?)?.toDouble() ?? 0,
      sprintCount: (map['sprint_count'] as num?)?.toInt() ?? 0,
      accelerationCount: (map['acceleration_count'] as num?)?.toInt() ?? 0,
      decelerationCount: (map['deceleration_count'] as num?)?.toInt() ?? 0,
      maxAcceleration: (map['max_acceleration'] as num?)?.toDouble() ?? 0,
      impactCount: (map['impact_count'] as num?)?.toInt() ?? 0,
      maxImpactG: (map['max_impact_g'] as num?)?.toDouble() ?? 0,
      hieCount: (map['hie_count'] as num?)?.toInt() ?? 0,
      playerLoad: (map['player_load'] as num?)?.toDouble() ?? 0,
      loadScore: (map['load_score'] as num?)?.toDouble() ?? 0,
      sessionIntensity: (map['session_intensity'] as num?)?.toDouble() ?? 0,
      fatigueIndex: (map['fatigue_index'] as num?)?.toDouble() ?? 0,
      hsrEfforts: (map['hsr_efforts'] as num?)?.toInt() ?? 0,
      distanceToMaxSpeedM:
          (map['distance_to_max_speed_m'] as num?)?.toDouble() ?? 0,
      hmldDistanceM: (map['hmld_distance_m'] as num?)?.toDouble() ?? 0,
      hmldPercentage: (map['hmld_percentage'] as num?)?.toDouble() ?? 0,
      hmldPerMin: (map['hmld_per_min'] as num?)?.toDouble() ?? 0,
      momentumPeak: (map['momentum_peak'] as num?)?.toDouble() ?? 0,
      energyKcal: (map['energy_kcal'] as num?)?.toDouble() ?? 0,
      powerPlayCount: (map['power_play_count'] as num?)?.toInt() ?? 0,
      personalMaxPercentage:
          (map['personal_max_percentage'] as num?)?.toDouble() ?? 0,
      above90PercentMax: map['above_90_percent_max'] == true,
      gpsQualityPercentage:
          (map['gps_quality_percentage'] as num?)?.toDouble() ?? 0,
      dataGapsCount: (map['data_gaps_count'] as num?)?.toInt() ?? 0,
      durationSeconds: (map['duration_seconds'] as num?)?.toInt() ?? 0,
      zoneDistances: _parseDoubleMap(map['zone_distances']),
      impactCountsByZone: _parseIntMap(map['impact_counts_by_zone']),
      zoneTimeSeconds: _parseIntMap(map['zone_time_seconds']),
    );
  }

  /// Converts to a map suitable for GraphQL mutation.
  Map<String, dynamic> toMap() {
    return {
      'total_distance': totalDistanceKm,
      'active_distance': activeDistanceKm,
      'distance_per_min': distancePerMin,
      'sprint_distance': sprintDistance,
      'hsr_distance': hsrDistance,
      'explosive_distance': explosiveDistance,
      'max_speed': topSpeedKmh,
      'avg_speed': avgSpeedKmh,
      'sprint_count': sprintCount,
      'acceleration_count': accelerationCount,
      'deceleration_count': decelerationCount,
      'max_acceleration': maxAcceleration,
      'impact_count': impactCount,
      'max_impact_g': maxImpactG,
      'hie_count': hieCount,
      'player_load': playerLoad,
      'load_score': loadScore,
      'session_intensity': sessionIntensity,
      'fatigue_index': fatigueIndex,
      'hsr_efforts': hsrEfforts,
      'distance_to_max_speed_m': distanceToMaxSpeedM,
      'hmld_distance_m': hmldDistanceM,
      'hmld_percentage': hmldPercentage,
      'hmld_per_min': hmldPerMin,
      'momentum_peak': momentumPeak,
      'energy_kcal': energyKcal,
      'power_play_count': powerPlayCount,
      'personal_max_percentage': personalMaxPercentage,
      'above_90_percent_max': above90PercentMax,
      'gps_quality_percentage': gpsQualityPercentage,
      'data_gaps_count': dataGapsCount,
      'duration_seconds': durationSeconds,
      'zone_distances': zoneDistances,
      'impact_counts_by_zone': impactCountsByZone,
      'zone_time_seconds': zoneTimeSeconds,
    };
  }

  SessionStats copyWith({
    double? totalDistanceKm,
    double? activeDistanceKm,
    double? distancePerMin,
    double? sprintDistance,
    double? hsrDistance,
    double? explosiveDistance,
    double? topSpeedKmh,
    double? avgSpeedKmh,
    int? sprintCount,
    int? accelerationCount,
    int? decelerationCount,
    double? maxAcceleration,
    int? impactCount,
    double? maxImpactG,
    int? hieCount,
    double? playerLoad,
    double? loadScore,
    double? sessionIntensity,
    double? fatigueIndex,
    int? hsrEfforts,
    double? distanceToMaxSpeedM,
    double? hmldDistanceM,
    double? hmldPercentage,
    double? hmldPerMin,
    double? momentumPeak,
    double? energyKcal,
    int? powerPlayCount,
    double? personalMaxPercentage,
    bool? above90PercentMax,
    double? gpsQualityPercentage,
    int? dataGapsCount,
    int? durationSeconds,
    Map<String, double>? zoneDistances,
    Map<String, int>? impactCountsByZone,
    Map<String, int>? zoneTimeSeconds,
  }) {
    return SessionStats(
      totalDistanceKm: totalDistanceKm ?? this.totalDistanceKm,
      activeDistanceKm: activeDistanceKm ?? this.activeDistanceKm,
      distancePerMin: distancePerMin ?? this.distancePerMin,
      sprintDistance: sprintDistance ?? this.sprintDistance,
      hsrDistance: hsrDistance ?? this.hsrDistance,
      explosiveDistance: explosiveDistance ?? this.explosiveDistance,
      topSpeedKmh: topSpeedKmh ?? this.topSpeedKmh,
      avgSpeedKmh: avgSpeedKmh ?? this.avgSpeedKmh,
      sprintCount: sprintCount ?? this.sprintCount,
      accelerationCount: accelerationCount ?? this.accelerationCount,
      decelerationCount: decelerationCount ?? this.decelerationCount,
      maxAcceleration: maxAcceleration ?? this.maxAcceleration,
      impactCount: impactCount ?? this.impactCount,
      maxImpactG: maxImpactG ?? this.maxImpactG,
      hieCount: hieCount ?? this.hieCount,
      playerLoad: playerLoad ?? this.playerLoad,
      loadScore: loadScore ?? this.loadScore,
      sessionIntensity: sessionIntensity ?? this.sessionIntensity,
      fatigueIndex: fatigueIndex ?? this.fatigueIndex,
      hsrEfforts: hsrEfforts ?? this.hsrEfforts,
      distanceToMaxSpeedM: distanceToMaxSpeedM ?? this.distanceToMaxSpeedM,
      hmldDistanceM: hmldDistanceM ?? this.hmldDistanceM,
      hmldPercentage: hmldPercentage ?? this.hmldPercentage,
      hmldPerMin: hmldPerMin ?? this.hmldPerMin,
      momentumPeak: momentumPeak ?? this.momentumPeak,
      energyKcal: energyKcal ?? this.energyKcal,
      powerPlayCount: powerPlayCount ?? this.powerPlayCount,
      personalMaxPercentage:
          personalMaxPercentage ?? this.personalMaxPercentage,
      above90PercentMax: above90PercentMax ?? this.above90PercentMax,
      gpsQualityPercentage: gpsQualityPercentage ?? this.gpsQualityPercentage,
      dataGapsCount: dataGapsCount ?? this.dataGapsCount,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      zoneDistances: zoneDistances ?? this.zoneDistances,
      impactCountsByZone: impactCountsByZone ?? this.impactCountsByZone,
      zoneTimeSeconds: zoneTimeSeconds ?? this.zoneTimeSeconds,
    );
  }

  static Map<String, double> _parseDoubleMap(dynamic raw) {
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), (v as num).toDouble()));
    }
    return {};
  }

  static Map<String, int> _parseIntMap(dynamic raw) {
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    }
    return {};
  }
}
