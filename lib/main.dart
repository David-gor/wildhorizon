import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WildHorizon',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final MapController _mapController = MapController();
  final _riderNameController = TextEditingController();
  final _riderBikeController = TextEditingController();

  int _navIndex = 0;
  List<RideEntry> _rides = [];

  String _areaName = 'Fremont Older Preserve, Bay Area';
  double _radiusMiles = 50;
  LatLng _mapCenter = const LatLng(37.2606, -122.0890);
  double _mapZoom = 10.5;
  bool _isLoadingTrails = false;
  String? _trailError;
  List<TrailData> _trails = [];
  List<FavoriteTrail> _favoriteTrails = [];
  int? _selectedTrailId;

  StreamSubscription<Position>? _trailCompletionSubscription;
  TrailData? _trailCompletionTarget;
  bool _trailCompletionReachedStart = false;
  DateTime? _trailCompletionStartAt;
  bool _trailCompletionSaved = false;
  double get _radiusMeters => _radiusMiles * 1609.34;
  final Distance _distance = const Distance();
  Timer? _mapViewSaveTimer;

  static const LatLng _defaultMapCenter = LatLng(37.2606, -122.0890);
  static const double _defaultMapZoom = 10.5;

  bool _latLngIsValid(LatLng p) {
    return p.latitude.isFinite &&
        p.longitude.isFinite &&
        p.latitude >= -90 &&
        p.latitude <= 90 &&
        p.longitude >= -180 &&
        p.longitude <= 180;
  }

  bool _zoomIsValid(double z) => z.isFinite && z >= 1 && z <= 22;

  void _resetMapViewToDefaults() {
    _mapCenter = _defaultMapCenter;
    _mapZoom = _defaultMapZoom;
  }

  void _ensureMapStateValid() {
    if (!_latLngIsValid(_mapCenter) || !_zoomIsValid(_mapZoom)) {
      _resetMapViewToDefaults();
    }
  }

  bool _boundsFinite(LatLngBounds b) {
    return b.north.isFinite &&
        b.south.isFinite &&
        b.east.isFinite &&
        b.west.isFinite &&
        _latLngIsValid(b.northWest) &&
        _latLngIsValid(b.southEast);
  }

  @override
  void initState() {
    super.initState();
    _loadLocalData();
  }

  @override
  void dispose() {
    _mapViewSaveTimer?.cancel();
    unawaited(_persistMapView());
    _trailCompletionSubscription?.cancel();
    _riderNameController.dispose();
    _riderBikeController.dispose();
    super.dispose();
  }

  Future<void> _loadLocalData() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    _riderNameController.text = prefs.getString('rider_name') ?? '';
    _riderBikeController.text = prefs.getString('rider_bike') ?? '';

    final raw = prefs.getString('rides_v1');
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _rides = decoded
            .map((e) => RideEntry.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _rides = [];
      }
    }

    final favRaw = prefs.getString('favorite_trails_v1');
    if (favRaw != null && favRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(favRaw) as List<dynamic>;
        _favoriteTrails = decoded
            .map((e) => FavoriteTrail.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _favoriteTrails = [];
      }
    }

    var restoredMap = false;
    final mapLat = double.tryParse(prefs.getString('map_center_lat') ?? '');
    final mapLng = double.tryParse(prefs.getString('map_center_lng') ?? '');
    final mapZoom = double.tryParse(prefs.getString('map_zoom') ?? '');
    if (mapLat != null && mapLng != null && mapZoom != null) {
      final c = LatLng(mapLat, mapLng);
      final z = mapZoom.clamp(3.0, 18.0);
      if (_latLngIsValid(c) && _zoomIsValid(z)) {
        _mapCenter = c;
        _mapZoom = z;
        restoredMap = true;
      } else {
        await prefs.remove('map_center_lat');
        await prefs.remove('map_center_lng');
        await prefs.remove('map_zoom');
      }
    }

    setState(() {});

    if (restoredMap) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _mapController.move(_mapCenter, _mapZoom);
      });
    }
  }

  Future<void> _persistMapView() async {
    if (!_latLngIsValid(_mapCenter) || !_zoomIsValid(_mapZoom)) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('map_center_lat', _mapCenter.latitude.toString());
    await prefs.setString('map_center_lng', _mapCenter.longitude.toString());
    await prefs.setString('map_zoom', _mapZoom.toString());
  }

  void _schedulePersistMapView() {
    _mapViewSaveTimer?.cancel();
    _mapViewSaveTimer = Timer(const Duration(milliseconds: 900), () {
      unawaited(_persistMapView());
    });
  }

  Future<void> _persistFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'favorite_trails_v1',
      jsonEncode(_favoriteTrails.map((f) => f.toJson()).toList()),
    );
  }

  bool _isFavorite(int osmId) =>
      _favoriteTrails.any((f) => f.osmId == osmId);

  LatLng _trailCenter(TrailData trail) {
    if (trail.points.isEmpty) {
      return _mapCenter;
    }
    if (trail.points.length == 1) {
      return trail.points.first;
    }
    return trail.points[trail.points.length ~/ 2];
  }

  Future<void> _toggleFavorite(TrailData trail) async {
    final messenger = ScaffoldMessenger.of(context);
    if (_isFavorite(trail.osmId)) {
      setState(() {
        _favoriteTrails.removeWhere((f) => f.osmId == trail.osmId);
      });
      await _persistFavorites();
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Removed "${trail.name}" from favorites')),
      );
      return;
    }
    final center = _trailCenter(trail);
    setState(() {
      _favoriteTrails.insert(
        0,
        FavoriteTrail(
          osmId: trail.osmId,
          name: trail.name,
          latitude: center.latitude,
          longitude: center.longitude,
          lengthKm: trail.lengthKm,
        ),
      );
    });
    await _persistFavorites();
    if (!mounted) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Saved "${trail.name}" to favorites')),
    );
  }

  void _openFavorite(FavoriteTrail favorite) {
    setState(() {
      _navIndex = 0;
    });
    TrailData? loaded;
    for (final t in _trails) {
      if (t.osmId == favorite.osmId) {
        loaded = t;
        break;
      }
    }
    if (loaded != null) {
      _focusTrailOnMap(loaded);
      _showTrailDetails(loaded);
      return;
    }
    final p = LatLng(favorite.latitude, favorite.longitude);
    if (!_latLngIsValid(p)) {
      return;
    }
    _mapController.move(p, 14);
    setState(() {
      _mapCenter = p;
      _mapZoom = 14;
      _selectedTrailId = null;
    });
    _schedulePersistMapView();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Jumped to saved spot — tap refresh on the map if the trail line is not visible.',
        ),
      ),
    );
  }

  Future<void> _removeFavorite(FavoriteTrail favorite) async {
    setState(() {
      _favoriteTrails.removeWhere((f) => f.osmId == favorite.osmId);
    });
    await _persistFavorites();
  }

  Future<void> _showFavoritesSheet() async {
    if (!mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.52,
          minChildSize: 0.28,
          maxChildSize: 0.92,
          builder: (dragContext, scrollController) {
            return StatefulBuilder(
              builder: (context, setModalState) {
                final sorted = [..._favoriteTrails]
                  ..sort((a, b) => b.savedAt.compareTo(a.savedAt));

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(
                        'Favorite trails',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Expanded(
                      child: sorted.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  'No favorites yet.\nTap a trail on the map, then the star to save it here.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: sorted.length,
                              itemBuilder: (context, index) {
                                final fav = sorted[index];
                                final subtitle = fav.lengthKm != null
                                    ? '${fav.lengthKm!.toStringAsFixed(1)} km'
                                    : 'Saved ${fav.savedLabel()}';
                                return ListTile(
                                  leading: const Icon(
                                    Icons.star,
                                    color: Colors.amber,
                                  ),
                                  title: Text(fav.name),
                                  subtitle: Text(subtitle),
                                  onTap: () {
                                    Navigator.of(sheetContext).pop();
                                    _openFavorite(fav);
                                  },
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: 'Remove favorite',
                                    onPressed: () async {
                                      await _removeFavorite(fav);
                                      setModalState(() {});
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  void _focusTrailOnMap(TrailData trail) {
    if (trail.points.isEmpty) {
      return;
    }
    setState(() {
      _selectedTrailId = trail.osmId;
    });
    if (trail.points.length == 1) {
      final p = trail.points.first;
      _mapController.move(p, 15);
      setState(() {
        _mapCenter = p;
        _mapZoom = 15;
      });
      _schedulePersistMapView();
      return;
    }
    try {
      final bounds = LatLngBounds.fromPoints(trail.points);
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(40),
          maxZoom: 17,
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final cam = _mapController.camera;
        final c = cam.center;
        final z = cam.zoom;
        if (!_latLngIsValid(c) || !_zoomIsValid(z)) {
          _resetMapViewToDefaults();
          _mapController.move(_mapCenter, _mapZoom);
        } else {
          setState(() {
            _mapCenter = c;
            _mapZoom = z.clamp(3.0, 18.0);
          });
        }
        _schedulePersistMapView();
      });
    } catch (_) {
      final mid = trail.points[trail.points.length ~/ 2];
      _mapController.move(mid, 14);
      setState(() {
        _mapCenter = mid;
        _mapZoom = 14;
      });
      _schedulePersistMapView();
    }
  }

  Future<void> _showBrowseTrailsSheet() async {
    if (_trails.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No trails loaded yet — pan to your area and tap refresh.',
          ),
        ),
      );
      return;
    }

    final searchController = TextEditingController();

    if (!mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.52,
          minChildSize: 0.28,
          maxChildSize: 0.92,
          builder: (dragContext, scrollController) {
            return StatefulBuilder(
              builder: (context, setModalState) {
                final q = searchController.text.trim().toLowerCase();
                final sorted = [..._trails]..sort(
                    (a, b) =>
                        a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                  );
                final filtered = q.isEmpty
                    ? sorted
                    : sorted
                          .where((t) => t.name.toLowerCase().contains(q))
                          .toList();

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(
                        'Browse trails',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: searchController,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search by name',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (_) => setModalState(() {}),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  'No trails match “${searchController.text.trim()}”.',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final trail = filtered[index];
                                return ListTile(
                                  leading: Icon(
                                    _isFavorite(trail.osmId)
                                        ? Icons.star
                                        : Icons.star_border,
                                    color: _isFavorite(trail.osmId)
                                        ? Colors.amber
                                        : null,
                                  ),
                                  title: Text(trail.name),
                                  subtitle: Text(
                                    '${trail.lengthKm.toStringAsFixed(1)} km · '
                                    '${_trailDifficultyDisplayLabel(trail)}',
                                  ),
                                  onTap: () {
                                    Navigator.of(sheetContext).pop();
                                    _focusTrailOnMap(trail);
                                  },
                                  onLongPress: () async {
                                    await _toggleFavorite(trail);
                                    setModalState(() {});
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
    searchController.dispose();
  }

  void _tryFocusTrailFromSearchQuery(String raw) {
    final q = raw.trim().toLowerCase();
    if (q.isEmpty) {
      return;
    }
    if (_trails.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Load trails first — tap refresh on the map.'),
        ),
      );
      return;
    }

    TrailData? exact;
    for (final t in _trails) {
      if (t.name.toLowerCase() == q) {
        exact = t;
        break;
      }
    }
    if (exact != null) {
      _focusTrailOnMap(exact);
      return;
    }

    final partial = _trails
        .where((t) => t.name.toLowerCase().contains(q))
        .toList();
    if (partial.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No trail matches “$raw”.')),
      );
      return;
    }
    partial.sort((a, b) {
      final byLen = a.name.length.compareTo(b.name.length);
      if (byLen != 0) {
        return byLen;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    _focusTrailOnMap(partial.first);
    if (partial.length > 1 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${partial.length} trails match — opened the shortest name. '
            'Use suggestions or Browse trails to pick another.',
          ),
        ),
      );
    }
  }

  Future<void> _persistRides() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'rides_v1',
      jsonEncode(_rides.map((r) => r.toJson()).toList()),
    );
  }

  Future<void> _saveRiderProfile() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('rider_name', _riderNameController.text.trim());
    await prefs.setString('rider_bike', _riderBikeController.text.trim());
    if (!mounted) {
      return;
    }
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Rider profile saved')));
  }

  void _addRide(RideEntry ride) {
    setState(() {
      _rides.insert(0, ride);
    });
    _persistRides();
  }

  void _removeRideAt(int index) {
    setState(() {
      _rides.removeAt(index);
    });
    _persistRides();
  }

  static const double _trailNearStartEndMeters = 95;
  static const int _trailVertexSample = 28;

  double _minDistanceMetersToAny(LatLng p, Iterable<LatLng> points) {
    var best = double.infinity;
    for (final q in points) {
      final d = _distance.as(LengthUnit.Meter, p, q);
      if (d < best) {
        best = d;
      }
    }
    return best;
  }

  bool _trailFormsShortLoop(TrailData trail) {
    if (trail.points.length < 8) {
      return false;
    }
    return _distance.as(
          LengthUnit.Meter,
          trail.points.first,
          trail.points.last,
        ) <=
        85;
  }

  Iterable<LatLng> _firstTrailSample(TrailData trail) {
    final n = math.min(_trailVertexSample, trail.points.length);
    return trail.points.take(n);
  }

  Iterable<LatLng> _lastTrailSample(TrailData trail) {
    final n = math.min(_trailVertexSample, trail.points.length);
    return trail.points.sublist(trail.points.length - n);
  }

  Future<void> _beginTrailCompletionTracking(TrailData trail) async {
    final old = _trailCompletionSubscription;
    _trailCompletionSubscription = null;
    await old?.cancel();

    if (!mounted) {
      return;
    }
    final servicesOn = await Geolocator.isLocationServiceEnabled();
    if (!servicesOn) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Turn on location services to auto-save when you finish the trail.',
          ),
        ),
      );
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Location permission is needed to detect trail start and finish.',
          ),
        ),
      );
      return;
    }

    _trailCompletionSaved = false;
    _trailCompletionReachedStart = false;
    _trailCompletionStartAt = null;
    setState(() {
      _trailCompletionTarget = trail;
    });

    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 20,
    );
    _trailCompletionSubscription = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(_handleTrailCompletionPosition, onError: (_) {});
  }

  void _handleTrailCompletionPosition(Position position) {
    if (!mounted || _trailCompletionSaved) {
      return;
    }
    final target = _trailCompletionTarget;
    if (target == null) {
      return;
    }

    final here = LatLng(position.latitude, position.longitude);
    final loop = _trailFormsShortLoop(target);

    if (!_trailCompletionReachedStart) {
      if (_minDistanceMetersToAny(here, _firstTrailSample(target)) <=
          _trailNearStartEndMeters) {
        _trailCompletionReachedStart = true;
        _trailCompletionStartAt = DateTime.now();
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Start reached — head to the end of "${target.name}" to save your ride.',
            ),
          ),
        );
      }
      return;
    }

    final startedAt = _trailCompletionStartAt;
    if (startedAt == null) {
      return;
    }
    final minSeconds = loop ? 95 : 28;
    if (DateTime.now().difference(startedAt).inSeconds < minSeconds) {
      return;
    }

    if (_minDistanceMetersToAny(here, _lastTrailSample(target)) <=
        _trailNearStartEndMeters) {
      _trailCompletionSaved = true;
      _trailCompletionSubscription?.cancel();
      _trailCompletionSubscription = null;
      final completed = target;
      setState(() {
        _trailCompletionTarget = null;
        _trailCompletionReachedStart = false;
        _trailCompletionStartAt = null;
      });
      _addRide(
        RideEntry(
          name: completed.name,
          notes:
              'Finished trail (auto-saved). ${_trailDifficultyDisplayLabel(completed)} · '
              '${completed.lengthKm.toStringAsFixed(2)} km · ${completed.highwayType}'
              '${completed.mtbScale != null ? ' · OSM ${completed.mtbScale}' : ''}'
              '${completed.mtbScale == null && completed.mtbScaleImba != null ? ' · IMBA ${completed.mtbScaleImba}' : ''}',
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _navIndex = 1;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved "${completed.name}" to Rides')),
      );
    }
  }

  void _cancelTrailCompletionTracking() {
    _trailCompletionSubscription?.cancel();
    _trailCompletionSubscription = null;
    setState(() {
      _trailCompletionTarget = null;
      _trailCompletionReachedStart = false;
      _trailCompletionStartAt = null;
      _trailCompletionSaved = false;
    });
  }

  void _zoomIn() {
    final nextZoom = (_mapZoom + 1).clamp(3.0, 18.0);
    _mapController.move(_mapCenter, nextZoom);
    setState(() {
      _mapZoom = nextZoom;
    });
  }

  void _zoomOut() {
    final nextZoom = (_mapZoom - 1).clamp(3.0, 18.0);
    _mapController.move(_mapCenter, nextZoom);
    setState(() {
      _mapZoom = nextZoom;
    });
  }

  void _onMapTap(TapPosition _, LatLng tappedPoint) {
    if (_trails.isEmpty) {
      return;
    }

    final thresholdMeters = 150000 / math.pow(2, _mapZoom);
    TrailData? closestTrail;
    double closestDistance = double.infinity;

    for (final trail in _trails) {
      for (final point in trail.points) {
        final meters = _distance.as(LengthUnit.Meter, tappedPoint, point);
        if (meters < closestDistance) {
          closestDistance = meters;
          closestTrail = trail;
        }
      }
    }

    if (closestTrail != null && closestDistance <= thresholdMeters) {
      setState(() {
        _selectedTrailId = closestTrail!.osmId;
      });
      _showTrailDetails(closestTrail);
    }
  }

  void _showTrailDetails(TrailData trail) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final isFavorite = _isFavorite(trail.osmId);
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          trail.name,
                          style: Theme.of(sheetContext).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          isFavorite ? Icons.star : Icons.star_border,
                          color: isFavorite ? Colors.amber.shade700 : null,
                        ),
                        tooltip: isFavorite
                            ? 'Remove from favorites'
                            : 'Add to favorites',
                        onPressed: () async {
                          await _toggleFavorite(trail);
                          setSheetState(() {});
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
              Text(
                'Track & auto-save: go near the trail start, then the finish. '
                'Your ride is saved automatically when you reach the end. '
                'Loops need a bit more time between start and finish.',
                style: Theme.of(sheetContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(label: Text('${trail.lengthKm.toStringAsFixed(2)} km')),
                  Chip(label: Text('Type: ${trail.highwayType}')),
                  if (trail.surface != null)
                    Chip(label: Text('Surface: ${trail.surface}')),
                  Chip(
                    avatar: const Icon(Icons.terrain, size: 18),
                    label: Text(
                      _trailDifficultyDisplayLabel(trail),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  _beginTrailCompletionTracking(trail);
                },
                icon: const Icon(Icons.route_outlined),
                label: const Text('Track & auto-save at finish'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.of(sheetContext).pop();
                  _addRide(
                    RideEntry(
                      name: trail.name,
                      notes:
                          '${_trailDifficultyDisplayLabel(trail)} · '
                          '${trail.lengthKm.toStringAsFixed(2)} km · ${trail.highwayType}'
                          '${trail.mtbScale != null ? ' · OSM ${trail.mtbScale}' : ''}'
                          '${trail.mtbScale == null && trail.mtbScaleImba != null ? ' · IMBA ${trail.mtbScaleImba}' : ''}',
                    ),
                  );
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Added to Rides')),
                  );
                },
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Add to my rides now'),
              ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showAddRideDialog() async {
    final nameController = TextEditingController();
    final notesController = TextEditingController();
    final result = await showDialog<RideEntry>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Add ride'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Ride name',
                    hintText: 'Example: Sunset Loop',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  textCapitalization: TextCapitalization.sentences,
                  keyboardType: TextInputType.multiline,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    hintText: 'Conditions, who you rode with, bike setup…',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) {
                  return;
                }
                Navigator.of(context).pop(
                  RideEntry(name: name, notes: notesController.text.trim()),
                );
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    nameController.dispose();
    notesController.dispose();

    if (result != null) {
      _addRide(result);
    }
  }

  Future<void> _showEditAreaDialog() async {
    final areaController = TextEditingController(text: _areaName);
    final radiusController = TextEditingController(
      text: _radiusMiles.toStringAsFixed(0),
    );

    final result = await showDialog<(String, double)>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit trail search area'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: areaController,
                decoration: const InputDecoration(
                  labelText: 'Location',
                  hintText: 'Example: Fremont Older Preserve, Bay Area',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: radiusController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Radius (miles)',
                  hintText: 'Example: 50',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final area = areaController.text.trim();
                final radius = double.tryParse(radiusController.text.trim());
                if (area.isNotEmpty && radius != null && radius > 0) {
                  Navigator.of(context).pop((area, radius));
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (result != null) {
      setState(() {
        _areaName = result.$1;
        _radiusMiles = result.$2;
      });
      await _loadTrails();
    }
  }

  Future<void> _loadTrails() async {
    _ensureMapStateValid();
    setState(() {
      _isLoadingTrails = true;
      _trailError = null;
    });

    LatLngBounds? bounds;
    try {
      final b = _mapController.camera.visibleBounds;
      bounds = _boundsFinite(b) ? b : null;
    } catch (_) {
      bounds = null;
    }
    final bbox = bounds;
    final hasBounds = bbox != null &&
        bbox.northWest.latitude != bbox.southEast.latitude &&
        bbox.northWest.longitude != bbox.southEast.longitude;
    // When bbox is unavailable, Overpass `around:` — cap to stay within API limits.
    final cappedRadiusMeters = _radiusMeters
        .clamp(1000, 100000)
        .toStringAsFixed(0);

    final spatial = hasBounds
        ? '(${bbox.south.toStringAsFixed(6)},${bbox.west.toStringAsFixed(6)},${bbox.north.toStringAsFixed(6)},${bbox.east.toStringAsFixed(6)})'
        : '(around:$cappedRadiusMeters,${_mapCenter.latitude.toStringAsFixed(6)},${_mapCenter.longitude.toStringAsFixed(6)})';

    // Only ways that are explicitly for bikes / MTB in OSM (not generic paths).
    final query =
        '''
[out:json][timeout:25];
(
  way["highway"="cycleway"]$spatial;
  way["highway"~"path|track"]["bicycle"~"yes|designated|permissive"]$spatial;
  way["highway"~"path|track"]["mtb"~"yes|designated|allowed|official"]$spatial;
  way["highway"~"path|track"]["mtb:scale"]["bicycle"!~"no"]$spatial;
);
out geom;
''';

    try {
      final trails = await _loadFromOverpass(query);
      if (!mounted) {
        return;
      }
      setState(() {
        _trails = trails;
        _trailError = null;
        if (_selectedTrailId != null &&
            !_trails.any((trail) => trail.osmId == _selectedTrailId)) {
          _selectedTrailId = null;
        }
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _trailError =
            'Could not load trails. Check your network and tap refresh.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingTrails = false;
        });
      }
    }
  }

  Future<List<TrailData>> _loadFromOverpass(String query) async {
    final response = await http.post(
      Uri.parse('https://overpass-api.de/api/interpreter'),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        // overpass-api.de returns 406 if User-Agent looks like a generic script
        // (e.g. Dart's default); use an identifiable app UA.
        'User-Agent':
            'WildHorizon/1.0 (OSM trail viewer; +https://openstreetmap.org/copyright)',
        'Accept': '*/*',
      },
      body: {'data': query},
    );

    if (response.statusCode != 200) {
      throw Exception('Overpass API returned ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final elements = (decoded['elements'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    final seenIds = <int>{};
    final trails = <TrailData>[];
    for (final element in elements) {
      final rawId = element['id'];
      if (rawId is! num) {
        continue;
      }
      final id = rawId.toInt();
      if (seenIds.contains(id)) {
        continue;
      }
      seenIds.add(id);

      final geometry = (element['geometry'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();

      final points = <LatLng>[];
      for (final point in geometry) {
        final lat = point['lat'];
        final lon = point['lon'];
        if (lat is num && lon is num) {
          points.add(LatLng(lat.toDouble(), lon.toDouble()));
        }
      }
      if (points.length > 1) {
        final hasPointInRadius = points.any(
          (point) =>
              _distance.as(LengthUnit.Meter, _mapCenter, point) <=
              _radiusMeters,
        );
        if (!hasPointInRadius) {
          continue;
        }

        final tags = (element['tags'] as Map<String, dynamic>? ?? {});
        if (!_isOsmBikeTrail(tags)) {
          continue;
        }
        final highway = (tags['highway'] as String?) ?? 'path';
        double lengthMeters = 0;
        for (var i = 1; i < points.length; i++) {
          lengthMeters += _distance.as(
            LengthUnit.Meter,
            points[i - 1],
            points[i],
          );
        }
        trails.add(
          TrailData(
            osmId: id,
            points: points,
            name: _trailNameFromOsmTags(tags, highway),
            highwayType: highway,
            surface: tags['surface'] as String?,
            mtbScale: tags['mtb:scale'] as String?,
            mtbScaleImba: tags['mtb:scale:imba'] as String?,
            lengthKm: lengthMeters / 1000,
          ),
        );
      }
    }
    return trails;
  }

  Widget _buildHomeTab(BuildContext context, String radiusLabel) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.place_outlined),
              title: const Text('Trail search area'),
              subtitle: Text('$_areaName ($radiusLabel-mile radius)'),
              trailing: TextButton(
                onPressed: _showEditAreaDialog,
                child: const Text('Edit'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Bike trails from OpenStreetMap via Overpass (no API key). Pan/zoom, then refresh.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton.filledTonal(
                onPressed: _isLoadingTrails ? null : _loadTrails,
                tooltip: 'Refresh bike trails now',
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Center: ${_mapCenter.latitude.toStringAsFixed(4)}, ${_mapCenter.longitude.toStringAsFixed(4)}  |  Zoom: ${_mapZoom.toStringAsFixed(1)}x',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: _showAddRideDialog,
            icon: const Icon(Icons.add_road),
            label: const Text('Add ride'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _showBrowseTrailsSheet,
                  icon: const Icon(Icons.list_alt_outlined),
                  label: const Text('Browse trails'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _showFavoritesSheet,
                  icon: const Icon(Icons.star_outline),
                  label: Text(
                    _favoriteTrails.isEmpty
                        ? 'Favorites'
                        : 'Favorites (${_favoriteTrails.length})',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Autocomplete<TrailData>(
            displayStringForOption: (trail) => trail.name,
            optionsBuilder: (TextEditingValue value) {
              final q = value.text.trim().toLowerCase();
              if (q.isEmpty || _trails.isEmpty) {
                return const Iterable<TrailData>.empty();
              }
              final list = _trails
                  .where((t) => t.name.toLowerCase().contains(q))
                  .toList();
              list.sort(
                (a, b) =>
                    a.name.toLowerCase().compareTo(b.name.toLowerCase()),
              );
              return list.take(20);
            },
            onSelected: (trail) {
              _focusTrailOnMap(trail);
              FocusManager.instance.primaryFocus?.unfocus();
            },
            fieldViewBuilder:
                (context, textController, focusNode, onFieldSubmitted) {
              return TextField(
                controller: textController,
                focusNode: focusNode,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: 'Search trail on map',
                  hintText: 'Type name, choose a suggestion, or press search',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: textController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            textController.clear();
                            setState(() {});
                          },
                        ),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (value) {
                  _tryFocusTrailFromSearchQuery(value);
                  FocusManager.instance.primaryFocus?.unfocus();
                },
              );
            },
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _mapCenter,
                      initialZoom: _mapZoom,
                      onMapReady: () {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            _loadTrails();
                          }
                        });
                      },
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all,
                      ),
                      onPositionChanged: (position, _) {
                        final center = position.center;
                        final zoom = position.zoom;
                        if (!_latLngIsValid(center) || !_zoomIsValid(zoom)) {
                          return;
                        }
                        setState(() {
                          _mapCenter = center;
                          _mapZoom = zoom.clamp(3.0, 18.0);
                        });
                        _schedulePersistMapView();
                      },
                      onTap: _onMapTap,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.wildhorizon',
                      ),
                      CircleLayer(
                        circles: [
                          CircleMarker(
                            point: _mapCenter,
                            radius: _radiusMeters,
                            useRadiusInMeter: true,
                            color: Colors.green.withAlpha(35),
                            borderColor: Colors.green.shade700,
                            borderStrokeWidth: 2,
                          ),
                        ],
                      ),
                      PolylineLayer(
                        polylines: _trails.map((trail) {
                          final selected = trail.osmId == _selectedTrailId;
                          final tier = _trailDifficultyTier(trail);
                          final lineColor = _trailDifficultyColor(tier);
                          final baseWidth = _mapZoom >= 13
                              ? 5.0
                              : _mapZoom >= 11
                              ? 4.0
                              : 3.0;
                          final expertDouble = !selected && tier == 3;
                          return Polyline(
                            points: trail.points,
                            color: lineColor,
                            strokeWidth: selected
                                ? baseWidth + 2
                                : baseWidth + (expertDouble ? 0.5 : 0),
                            borderStrokeWidth: selected
                                ? 3.5
                                : (expertDouble ? 2.25 : 0),
                            borderColor: selected
                                ? Colors.yellowAccent.shade400
                                : (expertDouble
                                      ? const Color(0xFFE0E0E0)
                                      : Colors.transparent),
                          );
                        }).toList(),
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _mapCenter,
                            width: 28,
                            height: 28,
                            child: const Icon(
                              Icons.my_location,
                              color: Colors.blue,
                            ),
                          ),
                        ],
                      ),
                      RichAttributionWidget(
                        attributions: [
                          TextSourceAttribution('OpenStreetMap contributors'),
                        ],
                      ),
                    ],
                  ),
                  if (_isLoadingTrails)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Color(0x44000000),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                  Positioned(
                    top: 12,
                    left: 12,
                    child: Card(
                      color: Colors.white.withAlpha(230),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            onPressed: _zoomIn,
                            tooltip: 'Zoom in',
                            icon: const Icon(Icons.add),
                          ),
                          const Divider(height: 1),
                          IconButton(
                            onPressed: _zoomOut,
                            tooltip: 'Zoom out',
                            icon: const Icon(Icons.remove),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_trailCompletionTarget != null)
                    Positioned(
                      left: 56,
                      right: 120,
                      top: 8,
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(8),
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.navigation_outlined,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _trailCompletionReachedStart
                                      ? 'Reach the end of "${_trailCompletionTarget!.name}" to save'
                                      : 'Go to the start of "${_trailCompletionTarget!.name}"',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.labelMedium,
                                ),
                              ),
                              TextButton(
                                onPressed: _cancelTrailCompletionTracking,
                                child: const Text('Stop'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Card(
                      color: Colors.white.withAlpha(230),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(
                          '${_trails.length} bike trails in $radiusLabel-mile radius',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 210),
                      child: Card(
                        color: Colors.white.withAlpha(235),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                          child: DefaultTextStyle(
                            style: Theme.of(context).textTheme.labelSmall!,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Trail difficulty (ski-style colors)',
                                  style: Theme.of(context).textTheme.labelMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 4),
                                for (final tier in const <int>[0, 1, 2, 3])
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Row(
                                      children: [
                                        _DifficultyLegendSwatch(tier: tier),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            _trailDifficultyLabel(tier),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _DifficultyLegendSwatch(tier: -1),
                                      const SizedBox(width: 6),
                                      const Expanded(
                                        child: Text(
                                          'Unrated — no difficulty tag in OpenStreetMap (grey lines)',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_trailError != null) ...[
            const SizedBox(height: 8),
            Text(
              _trailError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRidesTab(BuildContext context) {
    final rider = _riderNameController.text.trim();
    final bike = _riderBikeController.text.trim();
    String? riderLine;
    if (rider.isNotEmpty && bike.isNotEmpty) {
      riderLine = 'Rider: $rider · $bike';
    } else if (rider.isNotEmpty) {
      riderLine = 'Rider: $rider';
    } else if (bike.isNotEmpty) {
      riderLine = 'Bike: $bike';
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (riderLine != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                riderLine,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          FilledButton.icon(
            onPressed: _showAddRideDialog,
            icon: const Icon(Icons.add),
            label: const Text('Add ride'),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _rides.isEmpty
                ? Center(
                    child: Text(
                      'No rides saved yet.\nAdd one here, from a trail on the map, or use Add ride on Home.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _rides.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final ride = _rides[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 4,
                          horizontal: 4,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primaryContainer,
                          child: Icon(
                            Icons.directions_bike,
                            color: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
                          ),
                        ),
                        title: Text(ride.name),
                        subtitle: ride.notes.isEmpty
                            ? Text(ride.createdLabel())
                            : Text(
                                '${ride.notes}\n${ride.createdLabel()}',
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                              ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Remove ride',
                          onPressed: () => _removeRideAt(index),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTab(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Rider', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('Saved on this device only.', style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        TextField(
          controller: _riderNameController,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Display name',
            hintText: 'What we call you on Rides',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _riderBikeController,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Bike (optional)',
            hintText: 'e.g. Trek Fuel EX 8',
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saveRiderProfile,
          child: const Text('Save rider profile'),
        ),
        const SizedBox(height: 32),
        Text('About', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'WildHorizon loads bike trails from OpenStreetMap (Overpass). '
          'Rides, favorites, and rider profile are stored locally on this device.',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final radiusLabel = _radiusMiles.toStringAsFixed(0);
    const navTitles = ['WildHorizon', 'Rides', 'Settings'];

    return Scaffold(
      appBar: AppBar(title: Text(navTitles[_navIndex])),
      body: IndexedStack(
        index: _navIndex,
        children: [
          _buildHomeTab(context, radiusLabel),
          _buildRidesTab(context),
          _buildSettingsTab(context),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _navIndex,
        onDestinationSelected: (index) {
          setState(() {
            _navIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.directions_bike_outlined),
            selectedIcon: Icon(Icons.directions_bike),
            label: 'Rides',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

String? _trimmedOsmTag(Map<String, dynamic> tags, String key) {
  final value = tags[key];
  if (value is! String) {
    return null;
  }
  final t = value.trim();
  return t.isEmpty ? null : t;
}

/// OSM tagging must clearly allow cycling / MTB (excludes generic foot paths).
bool _isOsmBikeTrail(Map<String, dynamic> tags) {
  final bicycle = _trimmedOsmTag(tags, 'bicycle')?.toLowerCase();
  if (bicycle == 'no' || bicycle == 'use_sidepath') {
    return false;
  }

  final hw = _trimmedOsmTag(tags, 'highway')?.toLowerCase() ?? '';
  if (hw == 'cycleway') {
    return true;
  }
  if (hw != 'path' && hw != 'track') {
    return false;
  }

  if (RegExp(r'^(yes|designated|permissive)$').hasMatch(bicycle ?? '')) {
    return true;
  }

  final mtb = _trimmedOsmTag(tags, 'mtb')?.toLowerCase() ?? '';
  if (RegExp(r'^(yes|designated|allowed|official)$').hasMatch(mtb)) {
    return true;
  }

  if (_trimmedOsmTag(tags, 'mtb:scale') != null) {
    return true;
  }

  return false;
}

/// Best-effort label from OSM tags. Many paths have no `name` but do have
/// `ref`, `mtb:name`, route refs, endpoints, or other descriptive tags.
String _trailNameFromOsmTags(Map<String, dynamic> tags, String highwayType) {
  const nameKeys = [
    'name',
    'mtb:name',
    'official_name',
    'alt_name',
    'loc_name',
    'reg_name',
    'short_name',
    'designation',
  ];
  for (final key in nameKeys) {
    final s = _trimmedOsmTag(tags, key);
    if (s != null) {
      return s;
    }
  }

  const refKeys = [
    'ref',
    'mtb:ref',
    'nhn:ref',
    'usfs:trailid',
    'ncn_ref',
    'rcn_ref',
    'lcn_ref',
    'lwn_ref',
    'rwn_ref',
    'nwn_ref',
  ];
  for (final key in refKeys) {
    final r = _trimmedOsmTag(tags, key);
    if (r != null) {
      final network =
          _trimmedOsmTag(tags, 'network') ?? _trimmedOsmTag(tags, 'route');
      if (network != null && network.length <= 14) {
        return '$network $r';
      }
      return 'Trail $r';
    }
  }

  final destination = _trimmedOsmTag(tags, 'destination');
  if (destination != null) {
    return 'Toward $destination';
  }

  final from = _trimmedOsmTag(tags, 'from');
  final to = _trimmedOsmTag(tags, 'to');
  if (from != null && to != null) {
    return '$from – $to';
  }
  if (to != null) {
    return 'Toward $to';
  }
  if (from != null) {
    return 'From $from';
  }

  final desc = _trimmedOsmTag(tags, 'description');
  if (desc != null && desc.length <= 72) {
    return desc;
  }

  final parts = <String>[];
  final hw = highwayType.trim();
  if (hw.isNotEmpty) {
    parts.add(hw[0].toUpperCase() + hw.substring(1));
  }
  final surface = _trimmedOsmTag(tags, 'surface');
  if (surface != null) {
    parts.add(surface);
  }
  final scale = _trimmedOsmTag(tags, 'mtb:scale');
  if (scale != null) {
    parts.add('MTB $scale');
  }
  if (parts.isNotEmpty) {
    return parts.join(' · ');
  }
  return 'Unnamed trail';
}

int? _parseSacScaleDigit(String? raw) {
  if (raw == null) {
    return null;
  }
  final s = raw.trim();
  if (s.isEmpty) {
    return null;
  }
  final lower = s.toLowerCase();
  final m = RegExp(r'^[sS]?(\d)').firstMatch(lower);
  if (m != null) {
    return int.tryParse(m.group(1)!);
  }
  return null;
}

int? _parseImbaDigit(String? raw) {
  if (raw == null) {
    return null;
  }
  final s = raw.trim();
  if (s.isEmpty) {
    return null;
  }
  return int.tryParse(s[0]);
}

/// 0–6 = `mtb:scale` / mapped IMBA; -1 = unrated (grey), except [cycleway] → 0.
int _trailDifficultyBucket(TrailData trail) {
  final sac = _parseSacScaleDigit(trail.mtbScale);
  if (sac != null) {
    return sac.clamp(0, 6);
  }
  final imba = _parseImbaDigit(trail.mtbScaleImba);
  if (imba != null) {
    const imbaToSac = [0, 2, 3, 5, 6];
    return imbaToSac[imba.clamp(0, 4)];
  }
  if (trail.highwayType.toLowerCase() == 'cycleway') {
    return 0;
  }
  return -1;
}

Color _trailDifficultyColor(int bucket) {
  if (bucket < 0) {
    return const Color(0xFF546E7A);
  }
  const colors = <Color>[
    Color(0xFF1B5E20),
    Color(0xFF388E3C),
    Color(0xFF7CB342),
    Color(0xFFF9A825),
    Color(0xFFF57C00),
    Color(0xFFD84315),
    Color(0xFF4A148C),
  ];
  return colors[bucket.clamp(0, 6)];
}

/// Human-readable difficulty for map legend and trail sheet (from OSM bucket).
String _trailDifficultyLabel(int bucket) {
  if (bucket < 0) {
    return 'Unrated';
  }
  const labels = <String>[
    'Beginner',
    'Easy',
    'Intermediate',
    'Advanced',
    'Expert',
    'Extreme',
    'Pro',
  ];
  return labels[bucket.clamp(0, 6)];
}

class FavoriteTrail {
  FavoriteTrail({
    required this.osmId,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.lengthKm,
    DateTime? savedAt,
  }) : savedAt = savedAt ?? DateTime.now();

  final int osmId;
  final String name;
  final double latitude;
  final double longitude;
  final double? lengthKm;
  final DateTime savedAt;

  String savedLabel() {
    final d = savedAt;
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  Map<String, dynamic> toJson() => {
    'osmId': osmId,
    'name': name,
    'latitude': latitude,
    'longitude': longitude,
    if (lengthKm != null) 'lengthKm': lengthKm,
    'savedAt': savedAt.toIso8601String(),
  };

  factory FavoriteTrail.fromJson(Map<String, dynamic> json) {
    final osmRaw = json['osmId'];
    final lat = (json['latitude'] as num?)?.toDouble();
    final lng = (json['longitude'] as num?)?.toDouble();
    return FavoriteTrail(
      osmId: osmRaw is int ? osmRaw : (osmRaw as num).toInt(),
      name: (json['name'] as String?)?.trim() ?? 'Trail',
      latitude: lat ?? 0,
      longitude: lng ?? 0,
      lengthKm: (json['lengthKm'] as num?)?.toDouble(),
      savedAt:
          DateTime.tryParse(json['savedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

class RideEntry {
  RideEntry({required this.name, this.notes = '', DateTime? createdAt})
    : createdAt = createdAt ?? DateTime.now();

  final String name;
  final String notes;
  final DateTime createdAt;

  String createdLabel() {
    final d = createdAt;
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'notes': notes,
    'createdAt': createdAt.toIso8601String(),
  };

  factory RideEntry.fromJson(Map<String, dynamic> json) {
    final nameRaw = json['name'] as String? ?? '';
    final name = nameRaw.trim().isEmpty ? 'Ride' : nameRaw.trim();
    return RideEntry(
      name: name,
      notes: (json['notes'] as String?) ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class TrailData {
  const TrailData({
    required this.osmId,
    required this.points,
    required this.name,
    required this.highwayType,
    required this.lengthKm,
    this.surface,
    this.mtbScale,
    this.mtbScaleImba,
  });

  final int osmId;
  final List<LatLng> points;
  final String name;
  final String highwayType;
  final String? surface;
  final String? mtbScale;
  final String? mtbScaleImba;
  final double lengthKm;
}
