import 'dart:math' as math;

/// The season on the farm: it sets the scene's colours and its weather.
enum FarmSeason {
  spring('Spring'),
  summer('Summer'),
  autumn('Autumn'),
  winter('Winter');

  const FarmSeason(this.label);

  final String label;
}

/// Which half of the world the farm is in: it flips the seasons and the
/// length of the days. Saved in the farm's settings.
enum FarmHemisphere {
  north('Northern'),
  south('Southern');

  const FarmHemisphere(this.label);

  final String label;
}

/// Whether the farm's light follows the clock, or stays put.
enum FarmTimeOfDay {
  clock('Follow the clock'),
  day('Always day'),
  night('Always night');

  const FarmTimeOfDay(this.label);

  final String label;
}

/// The light and season on the farm at a moment.
///
/// [light] goes smoothly from 0 (night) to 1 (full day), easing over about
/// an hour around sunrise and sunset; [warmth] peaks at sunrise and sunset
/// (the orange of dawn and dusk). Sunrise and sunset follow the date, worked
/// out for a mid latitude (45°) in the farm's hemisphere, so winter evenings
/// are dark early and summer ones late. No location is needed.
class FarmSky {
  const FarmSky({
    required this.season,
    required this.light,
    required this.warmth,
    required this.sun,
    this.sunrise = 6,
    this.sunset = 18,
  });

  /// Noon on a spring day: what the farm looks like with no clock.
  static const day = FarmSky(season: FarmSeason.spring, light: 1, warmth: 0, sun: 0.5);

  factory FarmSky.at(
    DateTime time, {
    FarmHemisphere hemisphere = FarmHemisphere.north,
    FarmTimeOfDay timeOfDay = FarmTimeOfDay.clock,
  }) {
    final season = seasonOf(time, hemisphere);
    final (rise, set) = sunTimes(time, hemisphere);
    switch (timeOfDay) {
      case FarmTimeOfDay.day:
        return FarmSky(season: season, light: 1, warmth: 0, sun: 0.5, sunrise: rise, sunset: set);
      case FarmTimeOfDay.night:
        return FarmSky(season: season, light: 0, warmth: 0, sun: 0, sunrise: rise, sunset: set);
      case FarmTimeOfDay.clock:
        break;
    }
    final t = time.hour + time.minute / 60 + time.second / 3600;
    final light = _smooth(rise - 0.6, rise + 0.6, t) * (1 - _smooth(set - 0.6, set + 0.6, t));
    double bump(double c) => math.exp(-math.pow((t - c) / 0.7, 2).toDouble());
    return FarmSky(
      season: season,
      light: light,
      warmth: math.max(bump(rise), bump(set)),
      sun: ((t - rise) / (set - rise)).clamp(0.0, 1.0),
      sunrise: rise,
      sunset: set,
    );
  }

  final FarmSeason season;

  /// 0 at night to 1 in full day.
  final double light;

  /// 0 to 1: how orange the light is (dawn and dusk).
  final double warmth;

  /// Where the sun is across the day, 0 at sunrise to 1 at sunset: shadows
  /// fall west in the morning and east in the evening.
  final double sun;

  /// Sunrise and sunset, in hours after midnight.
  final double sunrise, sunset;

  /// 0 by day to 1 at night.
  double get darkness => 1 - light;

  /// Whether the animals are asleep (deep dusk or night).
  bool get asleep => light < 0.15;

  /// Rough: the light in steps of 2%, so the farm only repaints when it
  /// would look different.
  @override
  bool operator ==(Object other) =>
      other is FarmSky &&
      other.season == season &&
      (other.light * 50).round() == (light * 50).round() &&
      (other.warmth * 50).round() == (warmth * 50).round() &&
      (other.sun * 50).round() == (sun * 50).round();

  @override
  int get hashCode =>
      Object.hash(season, (light * 50).round(), (warmth * 50).round(), (sun * 50).round());

  /// The meteorological season: December to February is winter in the
  /// north and summer in the south.
  static FarmSeason seasonOf(DateTime time, FarmHemisphere hemisphere) {
    final north = switch (time.month) {
      12 || 1 || 2 => FarmSeason.winter,
      3 || 4 || 5 => FarmSeason.spring,
      6 || 7 || 8 => FarmSeason.summer,
      _ => FarmSeason.autumn,
    };
    if (hemisphere == FarmHemisphere.north) return north;
    return const {
      FarmSeason.winter: FarmSeason.summer,
      FarmSeason.summer: FarmSeason.winter,
      FarmSeason.spring: FarmSeason.autumn,
      FarmSeason.autumn: FarmSeason.spring,
    }[north]!;
  }

  /// Sunrise and sunset on [time]'s date, in hours, at 45° north or south,
  /// around a solar noon of 12:30 (about right with summer time).
  static (double, double) sunTimes(DateTime time, FarmHemisphere hemisphere) {
    final dayOfYear = time.difference(DateTime(time.year)).inDays;
    final declination = -23.44 * math.cos(2 * math.pi * (dayOfYear + 10) / 365) * math.pi / 180;
    final latitude = (hemisphere == FarmHemisphere.north ? 45 : -45) * math.pi / 180;
    final cosH = (-math.tan(latitude) * math.tan(declination)).clamp(-1.0, 1.0);
    final halfDay = math.acos(cosH) * 180 / math.pi / 15;
    return (12.5 - halfDay, 12.5 + halfDay);
  }

  static double _smooth(double a, double b, double x) {
    final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }
}
