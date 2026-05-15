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
  int? _selectedTrailId;

  StreamSubscription<Position>? _trailCompletionSubscription;
  TrailData? _trailCompletionTarget;
  bool _trailCompletionReachedStart = false;
  DateTime? _trailCompletionStartAt;
  bool _trailCompletionSaved = false;
  double get _radiusMeters => _radiusMiles * 1609.34;
  final Distance _distance = const Distance();
  Timer? _mapViewSaveTimer;

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

    var restoredMap = false;
    final mapLat = double.tryParse(prefs.getString('map_center_lat') ?? '');
    final mapLng = double.tryParse(prefs.getString('map_center_lng') ?? '');
    final mapZoom = double.tryParse(prefs.getString('map_zoom') ?? '');
    if (mapLat != null && mapLng != null && mapZoom != null) {
      _mapCenter = LatLng(mapLat, mapLng);
      _mapZoom = mapZoom.clamp(3.0, 18.0);
      restoredMap = true;
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
        setState(() {
          _mapCenter = cam.center;
          _mapZoom = cam.zoom;
        });
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
                                final bucket = _trailDifficultyBucket(trail);
                                return ListTile(
                                  title: Text(trail.name),
                                  subtitle: Text(
                                    '${trail.lengthKm.toStringAsFixed(1)} km · '
                                    '${_trailDifficultyLabel(bucket)}',
                                  ),
                                  onTap: () {
                                    Navigator.of(sheetContext).pop();
                                    _focusTrailOnMap(trail);
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
              '${completed.lengthKm.toStringAsFixed(2)} km · ${completed.highwayType}',
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
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                trail.name,
                style: Theme.of(sheetContext).textTheme.titleLarge,
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
                          '${trail.lengthKm.toStringAsFixed(2)} km · ${trail.highwayType}',
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
    setState(() {
      _isLoadingTrails = true;
      _trailError = null;
    });

    final bounds = _mapController.camera.visibleBounds;
    final hasBounds =
        bounds.northWest.latitude != bounds.southEast.latitude &&
        bounds.northWest.longitude != bounds.southEast.longitude;
    // When bbox is unavailable, Overpass `around:` — cap to stay within API limits.
    final cappedRadiusMeters = _radiusMeters
        .clamp(1000, 100000)
        .toStringAsFixed(0);

    final spatial = hasBounds
        ? '(${bounds.south.toStringAsFixed(6)},${bounds.west.toStringAsFixed(6)},${bounds.north.toStringAsFixed(6)},${bounds.east.toStringAsFixed(6)})'
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
            osmSacScale: tags['sac_scale'] as String?,
            tracktype: tags['tracktype'] as String?,
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
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _showAddRideDialog,
                  icon: const Icon(Icons.add_road),
                  label: const Text('Add ride'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _showBrowseTrailsSheet,
                  icon: const Icon(Icons.list_alt_outlined),
                  label: const Text('Browse trails'),
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
                        setState(() {
                          _mapCenter = center;
                          _mapZoom = zoom;
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
                                  'Line color = difficulty',
                                  style: Theme.of(context).textTheme.labelMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 4),
                                for (final tier in const <int>[0, 1, 2, 3])
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        _trailDifficultyLegendSwatch(tier),
                                        const SizedBox(width: 6),
                                        Text(_trailDifficultyLabel(tier)),
                                      ],
                                    ),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _trailDifficultyLegendSwatch(-1),
                                      const SizedBox(width: 6),
                                      const Expanded(
                                        child: Text(
                                          'Unrated — no MTB scale / sac_scale / tracktype / surface hint in OSM',
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
          'Ride list and rider profile are stored locally with SharedPreferences.',
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

/// Rough MTB bucket 0–6 from OSM `sac_scale` (hiking scale) when `mtb:scale` is missing.
int? _bucketFromOsmSacScaleTag(String? raw) {
  if (raw == null) {
    return null;
  }
  final s = raw.trim();
  if (s.isEmpty) {
    return null;
  }
  final lower = s.toLowerCase();
  final t = RegExp(r'^[tT]\s*(\d)').firstMatch(lower);
  if (t != null) {
    final d = int.tryParse(t.group(1)!);
    if (d != null) {
      return (d - 1).clamp(0, 6);
    }
  }
  switch (lower.replaceAll('-', '_')) {
    case 'hiking':
      return 0;
    case 'mountain_hiking':
      return 2;
    case 'demanding_mountain_hiking':
      return 3;
    case 'alpine_hiking':
      return 4;
    case 'demanding_alpine_hiking':
      return 5;
    case 'difficult_alpine_hiking':
      return 6;
    default:
      return null;
  }
}

/// Rough MTB bucket from OSM `tracktype` (surface firmness of tracks).
int? _bucketFromTracktype(String? raw) {
  if (raw == null) {
    return null;
  }
  final m = RegExp(
    r'grade\s*(\d)',
    caseSensitive: false,
  ).firstMatch(raw.trim());
  if (m == null) {
    return null;
  }
  final d = int.tryParse(m.group(1)!);
  if (d == null || d < 1 || d > 5) {
    return null;
  }
  const gradeToBucket = <int, int>{1: 0, 2: 1, 3: 2, 4: 4, 5: 5};
  return gradeToBucket[d];
}

/// Last-resort hint from `surface` when no better tags exist.
int? _bucketFromSurfaceHint(String? raw) {
  if (raw == null) {
    return null;
  }
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) {
    return null;
  }
  if (s.contains('paving') ||
      s.contains('paved') ||
      s.contains('asphalt') ||
      s.contains('concrete') ||
      s == 'paving_stones') {
    return 0;
  }
  if (s.contains('gravel') ||
      s.contains('compacted') ||
      s.contains('fine_gravel')) {
    return 1;
  }
  if (s == 'dirt' ||
      s == 'earth' ||
      s == 'ground' ||
      s == 'grass' ||
      s.contains('wood')) {
    return 2;
  }
  if (s.contains('rock') || s.contains('mud') || s.contains('sand')) {
    return 3;
  }
  return null;
}

/// Raw `mtb:scale` / IMBA-derived bucket 0–6, or -1 unrated, except [cycleway] → 0.
/// Falls back to hiking [sac_scale], [tracktype], then [surface] when MTB tags are absent.
int _trailSacMtbBucket(TrailData trail) {
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
  final fromSac = _bucketFromOsmSacScaleTag(trail.osmSacScale);
  if (fromSac != null) {
    return fromSac.clamp(0, 6);
  }
  final fromTrack = _bucketFromTracktype(trail.tracktype);
  if (fromTrack != null) {
    return fromTrack.clamp(0, 6);
  }
  final fromSurface = _bucketFromSurfaceHint(trail.surface);
  if (fromSurface != null) {
    return fromSurface.clamp(0, 6);
  }
  return -1;
}

/// Ski-style display tier: -1 unrated, 0 beginner, 1 intermediate, 2 advanced, 3 expert.
int _trailDifficultyTier(TrailData trail) {
  final b = _trailSacMtbBucket(trail);
  if (b < 0) {
    return -1;
  }
  if (b <= 1) {
    return 0;
  }
  if (b <= 3) {
    return 1;
  }
  if (b <= 5) {
    return 2;
  }
  return 3;
}

Color _trailDifficultyColor(int tier) {
  switch (tier) {
    case -1:
      return const Color(0xFFC62828);
    case 0:
      return const Color(0xFF2E7D32);
    case 1:
      return const Color(0xFF1565C0);
    case 2:
    case 3:
      return const Color(0xFF000000);
    default:
      return const Color(0xFFC62828);
  }
}

/// Labels for [tier] values from [_trailDifficultyTier] only.
String _trailDifficultyLabel(int tier) {
  switch (tier) {
    case -1:
      return 'Unrated';
    case 0:
      return 'Beginner';
    case 1:
      return 'Intermediate';
    case 2:
      return 'Advanced';
    case 3:
      return 'Expert';
    default:
      return 'Unrated';
  }
}

/// True when difficulty comes from `mtb:scale` / `mtb:scale:imba` or a cycleway default.
bool _trailDifficultyFromVerifiedOsmTags(TrailData trail) {
  if (trail.highwayType.toLowerCase() == 'cycleway') {
    return true;
  }
  if (_parseSacScaleDigit(trail.mtbScale) != null) {
    return true;
  }
  if (_parseImbaDigit(trail.mtbScaleImba) != null) {
    return true;
  }
  return false;
}

String _trailDifficultyDisplayLabel(TrailData trail) {
  final tier = _trailDifficultyTier(trail);
  final base = _trailDifficultyLabel(tier);
  if (tier < 0 || _trailDifficultyFromVerifiedOsmTags(trail)) {
    return base;
  }
  return '$base (est.)';
}

Widget _trailDifficultyLegendSwatch(int tier) {
  if (tier == 3) {
    return SizedBox(
      width: 14,
      height: 10,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(color: Colors.black26, width: 0.5),
              ),
            ),
          ),
          const SizedBox(width: 2),
          Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(color: Colors.black26, width: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
  return SizedBox(
    width: 14,
    height: 10,
    child: Center(
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: _trailDifficultyColor(tier),
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: Colors.black26, width: 0.5),
        ),
      ),
    ),
  );
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
    this.osmSacScale,
    this.tracktype,
  });

  final int osmId;
  final List<LatLng> points;
  final String name;
  final String highwayType;
  final String? surface;
  final String? mtbScale;
  final String? mtbScaleImba;
  /// Hiking `sac_scale` when `mtb:scale` is absent (OpenStreetMap).
  final String? osmSacScale;
  final String? tracktype;
  final double lengthKm;
}
