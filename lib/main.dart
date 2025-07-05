import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:weather_icons/weather_icons.dart';
import 'update_handler.dart';
import 'metar_weather_api.dart';
import 'package:fl_chart/fl_chart.dart';

@pragma("vm:entry-point")
void downloadCallback(String id, int status, int progress) {
  final SendPort? send = IsolateNameServer.lookupPortByName(
    "downloader_send_port",
  );
  if (send != null) {
    send.send([id, status, progress]);
  } else {
    debugPrint("DownloadCallback: No se encontró el puerto de envío");
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await FlutterDownloader.initialize(debug: false);
  FlutterDownloader.registerCallback(downloadCallback);

  // Configuramos el ReceivePort globalmente
  final ReceivePort port = ReceivePort();
  final String portName = "downloader_send_port";

  if (IsolateNameServer.lookupPortByName(portName) != null) {
    debugPrint(
      "ADVERTENCIA: Se encontró un SendPort existente con el nombre '$portName'. Removiendo para registrar el nuestro.",
    );
    IsolateNameServer.removePortNameMapping(portName);
  }

  IsolateNameServer.registerPortWithName(port.sendPort, portName);

  // Pasamos el ReceivePort a UpdateHandler
  UpdateScreenState().initialize(port);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WeatherService()),
        ChangeNotifierProvider(create: (_) => Checkers()),
        ChangeNotifierProvider(create: (_) => UpdateScreenState()),
      ],
      child: MaterialApp(
        title: "zeroweather",
        theme: ThemeData(
          textTheme: GoogleFonts.kanitTextTheme(),
          useMaterial3: true,
          //podemos cambiar el color de los temas de la app
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color.fromARGB(255, 62, 126, 134),
          ),
        ),
        home: MyHomePage(),
      ),
    );

    //return ChangeNotifierProvider(
    //  create: (context) => WeatherAPIState(),
    //  child: MaterialApp(
    //    title: "zeroweather",
    //    theme: ThemeData(
    //      textTheme: GoogleFonts.kanitTextTheme(),
    //      useMaterial3: true,
    //      //podemos cambiar el color de los temas de la app
    //      colorScheme: ColorScheme.fromSeed(
    //        seedColor: const Color.fromARGB(255, 62, 126, 134),
    //      ),
    //    ),
    //    home: MyHomePage(),
    //  ),
    //);
  }
}

//Checker para permisos de ubicación e internet
class Checkers with ChangeNotifier {
  var appPermission = true;

  final _eventController = StreamController<Map>.broadcast();
  Stream<Map> get eventStream => _eventController.stream;

  void emitEvent(Map event) {
    _eventController.add(event);
  }

  @override
  void dispose() {
    _eventController.close();
    super.dispose();
  }

  Future<void> checkPermissions() async {
    bool serviceEnabled;
    LocationPermission permission;
    try {
      //verificar si el servicio de ubicación está activo
      serviceEnabled = await Geolocator.isLocationServiceEnabled().timeout(
        Duration(seconds: 10),
      );
      if (!serviceEnabled) {
        throw Exception("El servicio de ubicación no está habilitado.");
      } else {}
      //verificar permisos de ubicación
      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception("No se han concedido los permisos de ubicación.");
        }
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception(
          "No se han concedido los permisos de ubicación de manera permanente.",
        );
      }
      appPermission = true;
      notifyListeners();
    } catch (e) {
      debugPrint("Error al obtener la ubicación: $e");
      appPermission = false;
    }
  }

  Future<void> checkInternet() async {
    try {
      final result = await InternetAddress.lookup(
        "google.com",
      ).timeout(Duration(seconds: 30));

      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        debugPrint("Conexión a internet.");
      } else {
        debugPrint("No hay conexión a internet.");
        emitEvent({"error": "Problema al verificar la conexión."});
      }
    } on SocketException {
      emitEvent({"error": "Error desconocido al verificar la conexión."});
    }
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  double _dayProgress = 0.0;
  Color _mainColor = const Color.fromARGB(255, 10, 91, 119);
  Color _titleTextColor = const Color.fromARGB(255, 244, 240, 88);
  Color _secondaryColor = const Color.fromARGB(255, 2, 1, 34);
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAsyncStuff();
    });
    Timer.periodic(const Duration(seconds: 1), (timer) {
      _updateDayProgressAndColors();
      setState(() {
        _isLoading = false;
        _updateDayProgressAndColors();
      });
    });
  }

  Future<void> _initAsyncStuff() async {
    setState(() {
      _isLoading = true;
    });

    final checkers = context.read<Checkers>();
    final newWeatherService = context.read<WeatherService>();

    try {
      await checkers.checkPermissions();
      await checkers.checkInternet();
      await Future.wait([
        newWeatherService.getPosition(),
        newWeatherService.loadStation(),
      ]);
      await newWeatherService.findNerbyStation();
      await Future.wait(
        [
              newWeatherService.getForecast(),
              newWeatherService.fetchMetarData(),
              newWeatherService.getICA(),
            ]
            as Iterable<Future>,
      );
    } catch (e) {
      debugPrint("Error en _initAsyncStuff: $e");
    }

    setState(() {
      _isLoading = false;
      _updateDayProgressAndColors();
    });

    final update = UpdateScreenState();
    update.checkForUpdates();
    bool _dialogShown = false;

    update.eventStream.listen((event) {
      debugPrint("Cargando evento: $event");
      if (event.keys.first == "show_update_dialog") {
        showDialog(
          context: context,
          barrierDismissible: !event.values.first["forceUpdate"],
          builder: (context) => AlertDialog(
            title: Text("Nueva versión disponible"),
            content: Text(
              "Versión ${event.values.first["latestVersion"]} disponible. ¿Deseas actualizar?",
            ),
            actions: [
              if (!event.values.first["forceUpdate"])
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text("Más tarde"),
                ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  update.downloadAndInstallApkAlt();
                },
                child: Text("Actualizar"),
              ),
            ],
          ),
        );
      } else if (event.containsKey("show_donwload_progress") && !_dialogShown) {
        _dialogShown = true;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => StreamBuilder<Map>(
            stream: update.downloadEventStream,
            builder: (context, snapshot) {
              String status = "Descargando actualización...";
              double progress = 0.0;

              if (snapshot.hasData) {
                if (snapshot.data!.containsKey("id")) {
                  final eventStatus = snapshot.data!["status"] as int;
                  final eventProgress = snapshot.data!["progress"] as int;
                  progress = eventProgress / 100.0;
                  status = eventStatus == DownloadTaskStatus.running.index
                      ? "Descargando... $eventProgress%"
                      : eventStatus == DownloadTaskStatus.complete.index
                      ? "Descarga completada, instalando..."
                      : eventStatus == DownloadTaskStatus.failed.index
                      ? "Error: Falló la descarga del APK"
                      : "Descarga cancelada";

                  if (eventStatus == DownloadTaskStatus.failed.index ||
                      eventStatus == DownloadTaskStatus.canceled.index) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (Navigator.canPop(context)) {
                        Navigator.pop(context);
                        _dialogShown = false;
                      }
                    });
                  }
                } else if (snapshot.data!.containsKey("error")) {
                  status = snapshot.data!["error"] as String;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (Navigator.canPop(context)) {
                      Navigator.pop(context);
                      _dialogShown = false;
                    }
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(status)));
                  });
                }
              }

              return AlertDialog(
                title: const Text("Descargando actualización"),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(status), // Mostrar el progreso dinámicamente
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: progress),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      FlutterDownloader.cancelAll();
                      _dialogShown = false;
                      Navigator.pop(context);
                    },
                    child: const Text("Cancelar"),
                  ),
                  ?status == "Descarga completada, instalando..."
                      ? TextButton(
                          onPressed: () {
                            update.installApk();
                          },
                          child: Text("Instalar Actualización"),
                        )
                      : null,
                ],
              );
            },
          ),
        );
      }
    });

    checkers.eventStream.listen((event) {
      if (event.entries.isNotEmpty) {
        showDialog(
          // ignore: use_build_context_synchronously
          context: context,
          builder: (_) => AlertDialog(
            title: Text("Error"),
            content: Text("${event.values.first}"),
            actions: [
              TextButton(
                onPressed: () {
                  SystemNavigator.pop();
                },
                child: Text("Salir"),
              ),
            ],
          ),
        );
      }
    });
  }

  void _updateDayProgressAndColors() {
    final forecastData = context.read<WeatherService>().forecastCachedData;
    final cloudDescription = context.read<WeatherService>().cloudDescription;

    //Valores por defecto
    double dayProgress = 0.0;
    var sunrise = DateTime.now();
    var sunset = DateTime.now().add(const Duration(hours: 12));

    if (forecastData != null &&
        forecastData.isNotEmpty &&
        cloudDescription.isNotEmpty) {
      try {
        //se intenta parsear los datos de amanecer y atardecer
        sunrise = DateTime.parse(forecastData["dailySunrise"]);
        sunset = DateTime.parse(forecastData["dailySunset"]);
        final totalDuration = sunset.difference(sunrise).inMinutes;
        final currentDuration = DateTime.now()
            .difference(sunrise)
            .inMinutes
            .clamp(0, totalDuration);
        // se saca la duración del día y se calcula el porcentaje de día
        dayProgress = totalDuration > 0 ? currentDuration / totalDuration : 0.0;
      } catch (e) {
        debugPrint("Error parseando las horas de amanecer y atardecer $e");
      }
    } else {
      // Valores por defecto: amanecer a las 6:00 AM, atardecer a las 6:00 PM
      final now = DateTime.now();
      sunrise = DateTime(now.year, now.month, now.day, 6, 0);
      sunset = DateTime(now.year, now.month, now.day, 18, 0);
      final totalDuration = sunset.difference(sunrise).inMinutes;
      final currentDuration = now
          .difference(sunrise)
          .inMinutes
          .clamp(0, totalDuration);
      dayProgress = totalDuration > 0 ? currentDuration / totalDuration : 0.0;
    }

    // Solo se actualiza si el cambio es significativo
    if ((dayProgress - _dayProgress).abs() > 0.01) {
      _dayProgress = dayProgress;
    }

    // Interpolación de colores para mainColor
    if (_dayProgress < 0.5) {
      _mainColor =
          Color.lerp(
            const Color.fromARGB(255, 10, 91, 119), // Amanecer
            const Color.fromARGB(255, 0, 128, 128), // Mediodía
            _dayProgress * 2,
          ) ??
          const Color.fromARGB(255, 0, 128, 128);
    } else if (_dayProgress < 0.75) {
      _mainColor =
          Color.lerp(
            const Color.fromARGB(255, 0, 128, 128), // Mediodía
            const Color.fromARGB(255, 139, 69, 19), // Atardecer
            (_dayProgress - 0.5) * 4,
          ) ??
          const Color.fromARGB(255, 0, 128, 128);
    } else {
      _mainColor =
          Color.lerp(
            const Color.fromARGB(255, 139, 69, 19), // Atardecer
            const Color.fromARGB(255, 175, 175, 216), // Noche
            (_dayProgress - 0.75) * 4,
          ) ??
          const Color.fromARGB(255, 100, 100, 160);
    }

    // Interpolación de colores para titleTextColor
    if (_dayProgress < 0.5) {
      _titleTextColor =
          Color.lerp(
            const Color.fromARGB(255, 244, 240, 88), // Amanecer
            const Color.fromARGB(255, 255, 215, 0), // Mediodía
            _dayProgress * 2,
          ) ??
          const Color.fromARGB(255, 255, 215, 0);
    } else if (_dayProgress < 0.75) {
      _titleTextColor =
          Color.lerp(
            const Color.fromARGB(255, 255, 215, 0), // Mediodía
            const Color.fromARGB(255, 255, 99, 71), // Atardecer
            (_dayProgress - 0.5) * 4,
          ) ??
          const Color.fromARGB(255, 255, 215, 0);
    } else {
      _titleTextColor =
          Color.lerp(
            const Color.fromARGB(255, 255, 99, 71), // Atardecer
            const Color.fromARGB(255, 200, 200, 255), // Noche
            (_dayProgress - 0.75) * 4,
          ) ??
          const Color.fromARGB(255, 200, 200, 255);
    }

    // Interpolación de colores para secondaryColor
    if (_dayProgress < 0.5) {
      _secondaryColor =
          Color.lerp(
            const Color.fromARGB(255, 2, 1, 34), // Amanecer
            const Color.fromARGB(255, 25, 25, 112), // Mediodía
            _dayProgress * 2,
          ) ??
          const Color.fromARGB(255, 25, 25, 112);
    } else if (_dayProgress < 0.75) {
      _secondaryColor =
          Color.lerp(
            const Color.fromARGB(255, 25, 25, 112), // Mediodía
            const Color.fromARGB(255, 128, 0, 0), // Atardecer
            (_dayProgress - 0.5) * 4,
          ) ??
          const Color.fromARGB(255, 25, 25, 112);
    } else {
      _secondaryColor =
          Color.lerp(
            const Color.fromARGB(255, 128, 0, 0), // Atardecer
            const Color.fromARGB(255, 120, 120, 180), // Noche
            (_dayProgress - 0.75) * 4,
          ) ??
          const Color.fromARGB(255, 120, 120, 180);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<WeatherService>(
      builder: (context, weatherService, child) {
        _updateDayProgressAndColors();

        final metarData = weatherService.metarCacheData;
        //final forecastData = weatherService.forecastCachedData;

        if (metarData == null || metarData.isEmpty) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: MovingCloudsBackground(
              dayProgress: _dayProgress,
              child: Center(
                child: StartPage(
                  mainColor: _mainColor,
                  secondaryColor: _secondaryColor,
                ),
              ),
            ),
          );
        }

        var newWeatherApi = context.watch<WeatherService>();

        var temp = newWeatherApi.metarCacheData!["temperature"].toString();
        var separatedTemp = temp.split(".");
        var tempByHours = newWeatherApi.forecastCachedData!["tempByHours"];
        var hours = newWeatherApi.forecastCachedData!["tempHours"];
        var dates = newWeatherApi.forecastCachedData!["dates"];
        var precipitation =
            newWeatherApi.forecastCachedData!["precipitationByHours"];

        var sunrise = DateTime.parse(
          newWeatherApi.forecastCachedData!["dailySunrise"],
        );
        var sunset = DateTime.parse(
          newWeatherApi.forecastCachedData!["dailySunset"],
        );

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: MovingCloudsBackground(
            dayProgress: _dayProgress,
            child: RefreshIndicator(
              color: _titleTextColor,
              backgroundColor: _mainColor,
              displacement: 20.0,
              edgeOffset: -10,
              onRefresh: () async {
                await newWeatherApi.getPrecisePosition().then((_) {
                  newWeatherApi.findNerbyStation();
                  newWeatherApi.getForecast();
                  newWeatherApi.fetchMetarData();
                  newWeatherApi.getICA();
                  _updateDayProgressAndColors();
                });
              },
              child: CustomScrollView(
                slivers: [
                  SliverList(
                    delegate: SliverChildListDelegate([
                      Padding(
                        padding: EdgeInsets.only(top: 90),
                        child: Column(
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            IndexPage(
                              weatherState: newWeatherApi,
                              mainColor: _mainColor,
                              separatedTemp: separatedTemp,
                              secondaryColor: _secondaryColor,
                              dayProgress: _dayProgress,
                              sunset: sunset,
                              sunrise: sunrise,
                              hours: (hours as List<dynamic>)
                                  .map((e) => e as int)
                                  .toList(),
                              tempByHours: (tempByHours as List<dynamic>)
                                  .map((e) => e as double)
                                  .toList(),
                              titleTextColor: _titleTextColor,
                              dates: (dates as List<dynamic>)
                                  .map((e) => DateTime.parse(e))
                                  .toList(),
                              precipitation: (precipitation as List<dynamic>)
                                  .map((e) => e as double)
                                  .toList(),
                            ),
                          ],
                        ),
                      ),
                    ]),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class IndexPage extends StatefulWidget {
  const IndexPage({
    super.key,
    required this.weatherState,
    required this.mainColor,
    required this.secondaryColor,
    required this.separatedTemp,
    required this.titleTextColor,
    required this.tempByHours,
    required this.hours,
    required this.dates,
    required this.precipitation,
    required this.dayProgress,
    required this.sunrise,
    required this.sunset,
  });
  final WeatherService weatherState;
  final Color mainColor;
  final Color secondaryColor;
  final List<String> separatedTemp;
  final Color titleTextColor;

  final List<double> tempByHours;
  final List<int> hours;
  final List<DateTime> dates;
  final List<double> precipitation;
  final double dayProgress;
  final DateTime sunrise;
  final DateTime sunset;

  @override
  State<IndexPage> createState() => _IndexPageState();
}

class _IndexPageState extends State<IndexPage> {
  late final WeatherService weatherState;
  late final Color mainColor;
  late final Color secondaryColor;
  late final List<String> separatedTemp;
  late final Color titleTextColor;
  late final List<double> tempByHours;
  late final List<int> hours;
  late final List<DateTime> dates;
  late final List<double> precipitation;
  late final double dayProgress;
  late final DateTime sunrise;
  late final DateTime sunset;

  @override
  void initState() {
    super.initState();
    weatherState = widget.weatherState;
    mainColor = widget.mainColor;
    secondaryColor = widget.secondaryColor;
    separatedTemp = widget.separatedTemp;
    titleTextColor = widget.titleTextColor;
    tempByHours = widget.tempByHours;
    hours = widget.hours;
    dates = widget.dates;
    precipitation = widget.precipitation;
    dayProgress = widget.dayProgress;
    sunrise = widget.sunrise;
    sunset = widget.sunset;
  }

  Color _getColor(double ica) {
    if (ica >= 3.01) {
      return Color.fromARGB(255, 126, 0, 35);
    } else if (ica >= 2.01) {
      return Color.fromARGB(255, 143, 63, 151);
    } else if (ica >= 1.51) {
      return Color.fromARGB(255, 255, 0, 0);
    } else if (ica >= 1.01) {
      return Color.fromARGB(255, 255, 126, 0);
    } else if (ica >= 0.51) {
      return Color.fromARGB(255, 255, 255, 0);
    } else if (ica >= 0) {
      return Color.fromARGB(255, 0, 228, 0);
    } else {
      return Colors.grey;
    }
  }

  Map<String, String> _getICAMessages(int ica) {
    if (ica <= 50) {
      return {"Bajo": "El aire es de buena calidad"};
    } else if (ica <= 100) {
      return {"Moderado": "La calidad del aire es media"};
    } else if (ica <= 150) {
      return {"Alto": "Nocivo para grupos sensibles"};
    } else if (ica <= 200) {
      return {"Muy alto": "Nocivo para la salud"};
    } else if (ica >= 300) {
      return {"Extremadamente alto": "Aire prácticamente venenoso"};
    }
    return {"Error": "No se pudienton obtener datos"};
  }

  IconData _getICAIcons(int ica) {
    if (ica <= 50) {
      return MdiIcons.emoticonHappy;
    } else if (ica <= 100) {
      return MdiIcons.emoticonNeutral;
    } else if (ica <= 150) {
      return MdiIcons.emoticonSad;
    } else if (ica <= 200) {
      return MdiIcons.emoticonCry;
    } else if (ica >= 300) {
      return MdiIcons.emoticonDead;
    }
    return WeatherIcons.alien;
  }

  @override
  Widget build(BuildContext context) {
    final spots = List.generate(
      hours.length,
      (i) => FlSpot(i.toDouble(), tempByHours[i]),
    );

    var intigerPart = separatedTemp[0];

    final linechartbardata = LineChartBarData(
      show: true,
      spots: spots,
      gradient: LinearGradient(
        colors: [
          Color.fromARGB(255, 217, 255, 1),
          Color.fromARGB(255, 217, 255, 1),
          Color.fromARGB(255, 217, 255, 1),
        ],
      ),
      barWidth: 4,
      isCurved: true,
      curveSmoothness: 0,
      isStrokeCapRound: true,
      isStrokeJoinRound: true,
      preventCurveOverShooting: true,
      dotData: FlDotData(
        show: true,
        getDotPainter:
            (
              FlSpot spot,
              double xPercentage,
              LineChartBarData bar,
              int index, {
              double? size,
            }) {
              return FlDotCirclePainter(
                radius: 5,
                color: Color.fromARGB(255, 217, 255, 1),
              );
            },
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Column(
          children: [
            Text(
              weatherState.siteName,
              style: TextStyle(fontSize: 30, color: mainColor),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < intigerPart.length; i++)
                  AnimatedSwitcher(
                    duration: Duration(milliseconds: 300),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.0, 0.1),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: Text(
                      intigerPart[i],
                      key: ValueKey(intigerPart[i]),
                      style: GoogleFonts.kanit(
                        fontSize: 105,
                        color: titleTextColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                Text(
                  ".",
                  style: GoogleFonts.kanit(
                    fontSize: 90,
                    color: titleTextColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                AnimatedSwitcher(
                  duration: Duration(milliseconds: 300),
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0.0, 0.1),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: Padding(
                    key: ValueKey(separatedTemp.isEmpty ? separatedTemp[1] : 0),
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      "${separatedTemp.isEmpty ? separatedTemp[1] : 0}",
                      style: GoogleFonts.kanit(
                        fontSize: 90,
                        color: titleTextColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                Text(
                  "C°",
                  style: GoogleFonts.kanit(
                    fontSize: 105,
                    color: titleTextColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
        Text(
          "↑${weatherState.forecastCachedData!["maxTemp"]}°/↓${weatherState.forecastCachedData!["minTemp"]}°",
          style: GoogleFonts.kanit(
            fontSize: 27,
            color: mainColor,
            fontWeight: FontWeight.w300,
          ),
        ),
        Text(
          "Sensación térmica: ${weatherState.metarCacheData!["heatIndex"]} °C",
          style: GoogleFonts.kanit(
            fontSize: 27,
            color: mainColor,
            fontWeight: FontWeight.w300,
          ),
        ),
        Container(
          margin: EdgeInsets.only(top: 20, left: 20, right: 20),
          child: Card(
            elevation: 10,
            clipBehavior: Clip.none,
            color: Color.fromARGB(90, 10, 91, 119),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadiusGeometry.all(Radius.circular(10)),
            ),
            child: Column(
              children: [
                tempByHours.isEmpty
                    ? Center(
                        child: SizedBox(
                          width: 100,
                          height: 200,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: mainColor,
                              strokeWidth: 5,
                            ),
                          ),
                        ),
                      )
                    : Padding(
                        padding: EdgeInsetsGeometry.only(top: 15),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              "Cielo ${weatherState.cloudDescription.keys.first} ",
                              style: GoogleFonts.kanit(
                                fontSize: 20,
                                color: Colors.white,
                                fontWeight: FontWeight.w300,
                              ),
                            ),
                            Icon(
                              weatherState.cloudDescription.values.single,
                              color: Colors.white,
                            ),
                          ],
                        ),
                      ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: RepaintBoundary(
                    child: SizedBox(
                      width: spots.length * 60,
                      height: 150,
                      child: LineChart(
                        LineChartData(
                          minX: 0,
                          maxX: spots.length - 1,
                          minY: (tempByHours.first) - 20,
                          maxY: (tempByHours.first) + 40,
                          //minY: 0,
                          //maxY: 100,
                          gridData: FlGridData(show: false),
                          borderData: FlBorderData(show: false),
                          clipData: FlClipData.none(),
                          lineTouchData: LineTouchData(
                            enabled: false,
                            touchTooltipData: LineTouchTooltipData(
                              tooltipBgColor: Color.fromARGB(0, 0, 0, 0),
                              tooltipMargin: 1,
                              tooltipPadding: EdgeInsets.all(20),
                              getTooltipItems:
                                  (List<LineBarSpot> touchedSpots) {
                                    return touchedSpots.map((barSpot) {
                                      final hour =
                                          hours[barSpot
                                              .spotIndex]; // lista de horas
                                      final temp = barSpot.y.toStringAsFixed(
                                        1,
                                      ); // temperatura
                                      final precip =
                                          precipitation[barSpot.spotIndex]
                                              .toInt(); // precipitación

                                      return LineTooltipItem(
                                        "$hour H\n $temp°C\n💧 $precip%",
                                        GoogleFonts.kanit(color: Colors.white),
                                      );
                                    }).toList();
                                  },
                            ),
                          ),
                          showingTooltipIndicators: List.generate(
                            spots.length,
                            (i) {
                              return ShowingTooltipIndicators([
                                LineBarSpot(linechartbardata, 0, spots[i]),
                              ]);
                            },
                          ),

                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(
                              axisNameWidget: Padding(
                                padding: EdgeInsets.all(10),
                              ),
                              sideTitles: SideTitles(
                                reservedSize: 11,
                                showTitles: true,
                                getTitlesWidget: (value, meta) {
                                  return Text("");
                                },
                              ),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                reservedSize: 40,
                                showTitles: false,
                                getTitlesWidget: (value, meta) {
                                  return Text("");
                                },
                              ),
                            ),

                            topTitles: const AxisTitles(
                              axisNameWidget: Padding(
                                padding: EdgeInsets.all(12),
                              ),
                              sideTitles: SideTitles(
                                reservedSize: 40,
                                showTitles: false,
                              ),
                            ),
                            rightTitles: AxisTitles(
                              axisNameWidget: const Padding(
                                padding: EdgeInsets.all(12),
                              ),
                              sideTitles: SideTitles(
                                reservedSize: 11,
                                showTitles: true,
                                getTitlesWidget: (value, meta) {
                                  return const Text("");
                                },
                              ),
                            ),
                          ),
                          lineBarsData: [linechartbardata],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Card(
          elevation: 10,
          color: Color.fromARGB(90, 10, 91, 119),
          child: SizedBox(
            height: 120,
            width: 340,
            child: Padding(
              padding: EdgeInsetsGeometry.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                spacing: 10,
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            "ICA ",
                            style: TextStyle(fontSize: 12, color: Colors.white),
                          ),
                          const Icon(
                            WeatherIcons.windy,
                            color: Colors.white,
                            size: 15,
                          ),
                        ],
                      ),
                      Text(
                        _getICAMessages(
                          weatherState.icaCache!["icaFinal"],
                        ).values.first,
                        style: TextStyle(fontSize: 15, color: Colors.white),
                      ),
                      Text(
                        "${_getICAMessages(weatherState.icaCache!["icaFinal"]).keys.first} (${weatherState.icaCache!["icaFinal"]})",
                        style: TextStyle(fontSize: 20, color: Colors.white),
                      ),

                      SizedBox(
                        height: 10,
                        width: 200,
                        child: LinearProgressIndicator(
                          borderRadius: BorderRadius.all(Radius.circular(600)),
                          backgroundColor: mainColor,
                          value:
                              ((weatherState.icaCache!["icaFinal"] *
                                      100 /
                                      100) ??
                                  0) /
                              500,
                          color: _getColor(
                            ((weatherState.icaCache!["icaFinal"] * 100 / 100) ??
                                    0) /
                                500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Icon(
                    _getICAIcons(weatherState.icaCache!["icaFinal"]),
                    size: 50,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ),
        ),
        Cards(weatherState: weatherState),
        SunCurve(progress: dayProgress, sunrise: sunrise, sunset: sunset),
      ],
    );
  }
}

class SunCurve extends StatelessWidget {
  const SunCurve({
    super.key,
    required this.progress,
    required this.sunset,
    required this.sunrise,
  });

  final double progress;
  final DateTime sunset;
  final DateTime sunrise;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsetsGeometry.only(bottom: 100),
      child: Card(
        elevation: 10,
        color: Color.fromARGB(90, 10, 91, 119),
        child: SizedBox(
          height: 200,
          width: 350,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(
                width: 300,
                height: 120,
                child: CustomPaint(painter: SunPathPainter(progress)),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      Text(
                        "Amanecer",
                        style: GoogleFonts.kanit(
                          color: Colors.white,
                          fontSize: 17,
                        ),
                      ),
                      Text(
                        "${sunrise.hour}:${sunrise.minute}",
                        style: GoogleFonts.kanit(color: Colors.white),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      Text(
                        "Atardecer",
                        style: GoogleFonts.kanit(
                          color: Colors.white,
                          fontSize: 17,
                        ),
                      ),
                      Text(
                        "${sunset.hour}:${sunset.minute}",
                        style: GoogleFonts.kanit(color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class StartPage extends StatelessWidget {
  const StartPage({
    super.key,
    required this.mainColor,
    required this.secondaryColor,
  });

  final Color mainColor;
  final Color secondaryColor;

  @override
  Widget build(BuildContext context) {
    var weatherState = context.watch<WeatherService>();
    var appPermission = weatherState.appPermission;

    return SizedBox(
      height: MediaQuery.of(context).size.height,
      width: MediaQuery.of(context).size.width,
      child: appPermission
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 30,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      "ZERO",
                      style: TextStyle(fontSize: 25, color: mainColor),
                    ),
                    Text(
                      "WEATHER",
                      style: TextStyle(fontSize: 25, color: secondaryColor),
                    ),
                  ],
                ),
                CircularProgressIndicator(color: mainColor, strokeWidth: 5),
              ],
            )
          : Center(
              child: Card(
                color: Color.fromARGB(66, 10, 92, 119),
                elevation: 10,
                child: SizedBox(
                  width: 350,
                  height: 100,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text("Por favor, conceda los permisos de ubicación."),
                        ElevatedButton(
                          onPressed: () {
                            SystemNavigator.pop();
                          },
                          style: ButtonStyle(
                            backgroundColor:
                                WidgetStateProperty.resolveWith<Color?>((
                                  Set<WidgetState> states,
                                ) {
                                  return Color.fromARGB(255, 217, 255, 1);
                                }),
                          ),
                          child: Text("Cerrar"),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class Cards extends StatelessWidget {
  Cards({super.key, required this.weatherState});

  final cardPadding = EdgeInsets.all(15);
  final WeatherService weatherState;
  double fontCardSize = 18.0;

  final mainCardColor = Color.fromARGB(150, 10, 91, 119);
  final secondaryCardColor = Color.fromARGB(255, 67, 237, 253);
  final titleTextColor = Color.fromARGB(255, 244, 240, 88);

  Map<String, String> _getuvmessage(double uvIndex) {
    if (uvIndex >= 1.1) {
      return {"Extremo!": "¡Peligro! Quédate en interiores"};
    } else if (uvIndex >= 0.8) {
      return {"Demasiado alto": "Evita la exposición al sol"};
    } else if (uvIndex >= 0.6) {
      return {"Muy alto": "Minimiza la exposición al sol"};
    } else if (uvIndex >= 0.3) {
      return {"Alto": "Poca precaución es necesaria"};
    } else if (uvIndex >= 0) {
      return {"Bajo": "No se requiere protección especial"};
    } else {
      return {"Error": "Datos no disponibles"};
    }
  }

  String _getDewPointClassification(double dewPoint, double temperature) {
    if (temperature < 16.0 && dewPoint < 10.0) {
      return "Frío y seco";
    } else if (temperature < 24.0 && dewPoint < 16.0) {
      return "Seco y cómodo";
    } else if (temperature < 28.0 && dewPoint >= 16.0 && dewPoint < 20.0) {
      return "Se está agradable";
    } else if (temperature < 28.0 && dewPoint >= 20.0) {
      return "Húmedo, pero templado";
    } else if (temperature >= 28.0 && dewPoint < 16.0) {
      return "Calor seco";
    } else if (temperature >= 28.0 && dewPoint >= 16.0 && dewPoint < 20.0) {
      return "Cálido con algo de humedad";
    } else if (temperature >= 28.0 && dewPoint >= 20.0 && dewPoint < 24.0) {
      return "Incomodidad moderada";
    } else if (temperature >= 30.0 && dewPoint >= 24.0) {
      return "Se siente sofocante";
    } else {
      return "Sensación variable";
    }
  }

  Map<String, String> _getPressureAlertMessage(double pressureHpa) {
    if (pressureHpa >= 1030.0) {
      return {"Muy Alta": "Tiempo muy estable"};
    } else if (pressureHpa >= 1018.0) {
      return {"Alta": "Tiempo estable y soleado"};
    } else if (pressureHpa >= 1008.0) {
      return {"Normal": "Condiciones meteorológicas típicas"};
    } else if (pressureHpa >= 995.0) {
      return {"Baja": "Puede esperarse lluvia, viento o cielos cubiertos."};
    } else if (pressureHpa < 995.0) {
      return {
        "Muy Baja":
            "Tiempo inestable y severo, con vientos fuertes o tormentas",
      };
    } else {
      return {"Error": "Datos no disponibles"};
    }
  }

  Map<String, String> _getPrecipitationMessage(double precipitationMm) {
    if (precipitationMm > 20.0) {
      return {
        "Lluvia Extrema":
            "¡Alerta! Posibles inundaciones, condiciones de conducción peligrosas",
      };
    } else if (precipitationMm > 8.0) {
      return {
        "Lluvia Fuerte":
            "Lluvias intensas esperadas. Considera reducir la velocidad al conducir",
      };
    } else if (precipitationMm > 2.5) {
      return {"Lluvia Moderada": "Lluvias continuas. Ten tu paraguas a mano"};
    } else if (precipitationMm > 0.0) {
      return {"Lluvia Ligera": "Posibilidad de llovizna o lluvia débil"};
    } else if (precipitationMm == 0.0) {
      return {"Sin Lluvia": "No se espera precipitación"};
    } else {
      return {"Error": "Datos no disponibles"};
    }
  }

  Map<String, String> _getHumidityMessage(double humidity) {
    if (humidity >= 70.0) {
      return {"Muy Alta": "Tiempo muy húmedo"};
    } else if (humidity >= 50.0) {
      return {"Alta": "Humedad considerable"};
    } else if (humidity >= 20.0) {
      return {"Moderada": "Niveles de humedad confortables"};
    } else if (humidity >= 10.0) {
      return {"Baja": "Aire bastante seco"};
    } else if (humidity < 10.0) {
      return {"Muy Baja": "Aire extremadamente seco"};
    } else {
      return {"Error": "Datos no disponibles"};
    }
  }

  @override
  Widget build(BuildContext context) {
    final double uv =
        (weatherState.forecastCachedData!["dailyUVIndexMax"][0] ?? 1)
            .toDouble();
    final double clampedUV = uv.clamp(0.0, 11.0);
    return Container(
      margin: const EdgeInsets.all(1),
      child: GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        padding: EdgeInsets.all(20),
        shrinkWrap: true,
        physics: NeverScrollableScrollPhysics(),
        childAspectRatio: (1 / 1.1),
        children: [
          Card(
            elevation: 10,
            color: mainCardColor,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        "Índice UV ",
                        style: GoogleFonts.kanit(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const Icon(Icons.sunny, color: Colors.white, size: 15),
                    ],
                  ),
                  Text(
                    _getuvmessage(
                      (weatherState.forecastCachedData!["dailyUVIndexMax"][0] ??
                              1) /
                          10,
                    ).entries.first.value,
                    style: GoogleFonts.kanit(fontSize: 17, color: Colors.white),
                  ),
                  Padding(
                    padding: EdgeInsetsGeometry.only(top: 5),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _getuvmessage(
                            (weatherState
                                        .forecastCachedData!["dailyUVIndexMax"][0] ??
                                    1) /
                                10,
                          ).keys.first,
                          style: GoogleFonts.kanit(
                            fontSize: fontCardSize,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(
                          height: 30,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Container(
                                height: 12,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(100),
                                  gradient: const LinearGradient(
                                    colors: [
                                      Colors.green,
                                      Colors.yellow,
                                      Colors.orange,
                                      Colors.red,
                                      Colors.deepPurple,
                                    ],
                                    stops: [0, 0.3, 0.6, 0.8, 1.0],
                                  ),
                                ),
                              ),
                              Positioned(
                                left: clampedUV * 10,
                                top: -4,
                                child: Container(
                                  width: 20,
                                  height: 20,
                                  decoration: BoxDecoration(
                                    color: (() {
                                      final ratio = (clampedUV / 11.0);
                                      if (ratio < 0.3) {
                                        return const Color.fromARGB(
                                          255,
                                          70,
                                          160,
                                          73,
                                        );
                                      }
                                      if (ratio < 0.6) {
                                        return const Color.fromARGB(
                                          255,
                                          206,
                                          190,
                                          49,
                                        );
                                      }
                                      if (ratio < 0.8) {
                                        return const Color.fromARGB(
                                          255,
                                          230,
                                          138,
                                          1,
                                        );
                                      }
                                      if (ratio < 1.0) {
                                        return const Color.fromARGB(
                                          255,
                                          221,
                                          61,
                                          49,
                                        );
                                      }
                                      return Colors.deepPurple;
                                    })(),
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Center(
                                    child: Text(
                                      "${weatherState.forecastCachedData!["dailyUVIndexMax"][0].toInt()}",
                                      style: GoogleFonts.kanit(
                                        height: -0.1,
                                        fontSize: 16,
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          Card(
            elevation: 10,
            color: mainCardColor,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Text(
                        "Viento ",
                        style: GoogleFonts.kanit(
                          fontSize: 13,
                          color: Colors.white,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const Icon(
                        WeatherIcons.wind,
                        color: Colors.white,
                        size: 16,
                      ),
                    ],
                  ),
                  Text(
                    "${weatherState.metarCacheData!["windSpeed"]} km/h",
                    style: GoogleFonts.kanit(
                      color: Colors.white,
                      fontSize: fontCardSize,
                    ),
                  ),

                  SizedBox(
                    height: 90,
                    width: 90,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 85,
                          height: 85,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.grey, width: 10),
                          ),
                        ),

                        Positioned(
                          top: -7,
                          child: Text(
                            "N",
                            style: GoogleFonts.kanit(
                              fontSize: 20,
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: -7,
                          child: Text(
                            "S",
                            style: GoogleFonts.kanit(
                              fontSize: 20,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0.5,
                          child: Text(
                            "O",
                            style: GoogleFonts.kanit(
                              fontSize: 20,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 2.2,
                          child: Text(
                            "E",
                            style: GoogleFonts.kanit(
                              fontSize: 20,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),

                        Positioned(
                          top: 7,
                          left: 8,
                          child: Transform.rotate(
                            angle: 150,
                            child: Text(
                              "NO",
                              style: GoogleFonts.kanit(
                                fontSize: 15,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Transform.rotate(
                            angle: 151.6,
                            child: Text(
                              "NE",
                              style: GoogleFonts.kanit(
                                fontSize: 15,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),

                        Positioned(
                          bottom: 8,
                          left: 10,
                          child: Transform.rotate(
                            angle: 151.6,
                            child: Text(
                              "SO",
                              style: GoogleFonts.kanit(
                                fontSize: 15,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 8,
                          right: 11,
                          child: Transform.rotate(
                            angle: 156.3,
                            child: Text(
                              "SE",
                              style: GoogleFonts.kanit(
                                fontSize: 15,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),

                        Transform.rotate(
                          angle:
                              weatherState.metarCacheData!["widDirection"] ?? 0,
                          child: Icon(
                            Icons.navigation,
                            size: 40,
                            color: titleTextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            color: mainCardColor,
            elevation: 10,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 10,
                children: [
                  Row(
                    children: [
                      Text(
                        "Presión ",
                        style: GoogleFonts.kanit(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const Icon(
                        WeatherIcons.barometer,
                        color: Colors.white,
                        size: 15,
                      ),
                    ],
                  ),
                  Text(
                    _getPressureAlertMessage(
                      double.parse(
                        weatherState.metarCacheData!["pressure"] ?? 0,
                      ),
                    ).values.first,
                    style: GoogleFonts.kanit(fontSize: 12, color: Colors.white),
                  ),
                  Padding(
                    padding: EdgeInsetsGeometry.only(top: 0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _getPressureAlertMessage(
                            double.parse(
                              weatherState.metarCacheData!["pressure"],
                            ),
                          ).keys.first,
                          style: GoogleFonts.kanit(
                            fontSize: fontCardSize,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          "${weatherState.metarCacheData!["pressure"]} hPa",
                          style: GoogleFonts.kanit(
                            fontSize: fontCardSize,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(
                          height: 10,
                          child: LinearProgressIndicator(
                            borderRadius: BorderRadius.all(
                              Radius.circular(600),
                            ),
                            value:
                                (double.parse(
                                  weatherState.metarCacheData!["pressure"],
                                )) /
                                2000,
                            color: secondaryCardColor,
                            backgroundColor: mainCardColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          Card(
            color: mainCardColor,
            elevation: 10,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        "Precipitación ",
                        style: GoogleFonts.kanit(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const Icon(
                        WeatherIcons.raindrops,
                        color: Colors.white,
                        size: 18,
                      ),
                    ],
                  ),
                  Text(
                    _getPrecipitationMessage(
                      weatherState
                          .forecastCachedData!["precipitationByHours"][0],
                    ).values.first,
                    style: GoogleFonts.kanit(
                      fontSize: 15,
                      color: Colors.white,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsetsGeometry.only(top: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        Text(
                          _getPrecipitationMessage(
                            weatherState
                                .forecastCachedData!["precipitationByHours"][0],
                          ).keys.first,
                          style: GoogleFonts.kanit(
                            fontSize: fontCardSize,
                            color: Colors.white,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                        Text(
                          "${weatherState.forecastCachedData!["precipitationByHours"][0]} mm",
                          style: GoogleFonts.kanit(
                            fontSize: fontCardSize,
                            color: Colors.white,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            color: mainCardColor,
            elevation: 10,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        "Punto de rocío ",
                        style: GoogleFonts.kanit(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const Icon(
                        Icons.dew_point,
                        color: Colors.white,
                        size: 15,
                      ),
                    ],
                  ),
                  Padding(
                    padding: EdgeInsetsGeometry.only(top: 20),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _getDewPointClassification(
                            weatherState.metarCacheData!["dewPoint"],
                            weatherState.metarCacheData!["temperature"],
                          ),
                          style: GoogleFonts.kanit(
                            fontSize: fontCardSize,
                            color: Colors.white,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                        Text(
                          "${weatherState.metarCacheData!["dewPoint"]} °C",
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w300,
                            color: titleTextColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          Card(
            color: mainCardColor,
            elevation: 10,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        "Humedad: ",
                        style: GoogleFonts.kanit(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const Icon(
                        WeatherIcons.humidity,
                        color: Colors.white,
                        size: 13,
                      ),
                    ],
                  ),
                  Text(
                    _getHumidityMessage(
                      (weatherState.metarCacheData!["humidity"] ?? 1),
                    ).values.first,
                    style: GoogleFonts.kanit(
                      fontSize: 18,
                      color: Colors.white,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsetsGeometry.only(top: 6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "${weatherState.metarCacheData!["humidity"]} %",
                          style: GoogleFonts.kanit(
                            fontSize: fontCardSize + 2,
                            color: Colors.white,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                        SizedBox(
                          height: 10,
                          child: LinearProgressIndicator(
                            borderRadius: BorderRadius.all(
                              Radius.circular(600),
                            ),
                            value:
                                (weatherState.metarCacheData!["humidity"] ??
                                    1) /
                                100,
                            color: secondaryCardColor,
                            backgroundColor: mainCardColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MovingCloudsBackground extends StatefulWidget {
  final Widget child;
  final double dayProgress;
  const MovingCloudsBackground({
    super.key,
    required this.child,
    required this.dayProgress,
  });

  @override
  _MovingCloudsBackgroundState createState() => _MovingCloudsBackgroundState();
}

class _MovingCloudsBackgroundState extends State<MovingCloudsBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late double dayProgress;

  var cloud1X;
  var cloud2X;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: Duration(seconds: 50),
    )..repeat();
    _controller.addListener(() {
      setState(() {});
    });
    dayProgress = widget.dayProgress;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        return CustomPaint(
          painter: CloudyBakcgroundPainter(
            dayProgress: dayProgress,
            cloud1X: 0.2 + 0.1 * sin(2 * pi * _controller.value),
            cloud2X: 0.41 + 0.11 * sin(5 * pi * _controller.value),
            cloud3X: 0.21 + 0.33 * sin(5 * pi * _controller.value),
          ),
          child: widget.child,
        );
      },
    );
  }
}

class CloudyBakcgroundPainter extends CustomPainter {
  CloudyBakcgroundPainter({
    required this.cloud1X,
    required this.cloud2X,
    required this.cloud3X,
    required this.dayProgress,
  });

  final double cloud1X;
  final double cloud2X;
  final double cloud3X;
  double dayProgress;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 60);
    // Fondo dinámico
    final Color backgroundColor;
    if (dayProgress < 0.5) {
      // Amanecer a mediodía
      backgroundColor =
          Color.lerp(
            const Color.fromARGB(255, 253, 132, 152), // Amanecer
            const Color.fromARGB(255, 135, 206, 235), // Mediodía
            dayProgress * 2,
          ) ??
          const Color.fromARGB(255, 135, 206, 235);
    } else if (dayProgress < 0.75) {
      // Mediodía a atardecer
      backgroundColor =
          Color.lerp(
            const Color.fromARGB(255, 135, 206, 235), // Mediodía
            const Color.fromARGB(255, 255, 145, 0), // Atardecer
            (dayProgress - 0.5) * 4,
          ) ??
          const Color.fromARGB(255, 135, 206, 235);
    } else {
      // Atardecer a noche
      backgroundColor =
          Color.lerp(
            const Color.fromARGB(255, 255, 140, 0), // Atardecer
            const Color.fromARGB(255, 76, 10, 231), // Noche
            (dayProgress - 0.75) * 4,
          ) ??
          const Color.fromARGB(255, 0, 0, 139);
    }

    paint.color = backgroundColor;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);

    // Paleta para el primer círculo
    final Color cloud1Color;
    if (dayProgress < 0.5) {
      // Amanecer a mediodía
      cloud1Color =
          Color.lerp(
            const Color.fromARGB(255, 255, 182, 193), // Amanecer
            const Color.fromARGB(255, 201, 255, 5), // Mediodía
            dayProgress * 2,
          ) ??
          const Color.fromARGB(255, 201, 255, 5);
    } else if (dayProgress < 0.75) {
      // Mediodía a atardecer
      cloud1Color =
          Color.lerp(
            const Color.fromARGB(255, 201, 255, 5), // Mediodía
            const Color.fromARGB(
              255,
              247,
              221,
              207,
            ), // Atardecer: rojo anaranjado
            (dayProgress - 0.5) * 4,
          ) ??
          const Color.fromARGB(255, 201, 255, 5);
    } else {
      // Atardecer a noche
      cloud1Color =
          Color.lerp(
            const Color.fromARGB(
              255,
              231,
              227,
              226,
            ), // Atardecer: rojo anaranjado
            const Color.fromARGB(255, 200, 200, 255), // Noche
            (dayProgress - 0.75) * 4,
          ) ??
          const Color.fromARGB(255, 25, 25, 112);
    }

    paint.color = cloud1Color;
    canvas.drawCircle(
      Offset(size.width * cloud1X, size.height * 0.2),
      100,
      paint,
    );

    // Paleta para el segundo círculo
    final Color cloud2Color;
    if (dayProgress < 0.5) {
      cloud2Color =
          Color.lerp(
            const Color.fromARGB(206, 255, 218, 185), // Amanecer
            const Color.fromARGB(206, 218, 245, 255), // Mediodía
            dayProgress * 2,
          ) ??
          const Color.fromARGB(206, 218, 245, 255);
    } else if (dayProgress < 0.75) {
      cloud2Color =
          Color.lerp(
            const Color.fromARGB(206, 218, 245, 255), // Mediodía
            const Color.fromARGB(
              206,
              247,
              216,
              175,
            ), // Atardecer: naranja oscuro
            (dayProgress - 0.5) * 4,
          ) ??
          const Color.fromARGB(206, 218, 245, 255);
    } else {
      cloud2Color =
          Color.lerp(
            const Color.fromARGB(
              206,
              155,
              113,
              63,
            ), // Atardecer: naranja oscuro
            const Color.fromARGB(206, 118, 83, 243), // Noche
            (dayProgress - 0.75) * 4,
          ) ??
          const Color.fromARGB(206, 47, 79, 79);
    }

    paint.color = cloud2Color;
    canvas.drawCircle(
      Offset(size.width * cloud2X, size.height * 0.3),
      150,
      paint,
    );
    // Paleta para el tercer círculo
    final Color cloud3Color;
    if (dayProgress < 0.5) {
      cloud3Color =
          Color.lerp(
            const Color.fromARGB(146, 255, 145, 101), // Amanecer
            const Color.fromARGB(146, 218, 245, 255), // Mediodía
            dayProgress * 2,
          ) ??
          const Color.fromARGB(146, 218, 245, 255);
    } else if (dayProgress < 0.75) {
      cloud3Color =
          Color.lerp(
            const Color.fromARGB(146, 218, 245, 255), // Mediodía
            const Color.fromARGB(146, 194, 228, 2), // Atardecer
            (dayProgress - 0.5) * 4,
          ) ??
          const Color.fromARGB(146, 218, 245, 255);
    } else {
      cloud3Color =
          Color.lerp(
            const Color.fromARGB(146, 255, 0, 64), // Atardecer
            const Color.fromARGB(85, 0, 255, 149), // Noche
            (dayProgress - 0.75) * 4,
          ) ??
          const Color.fromARGB(146, 0, 0, 139);
    }

    paint.color = cloud3Color;
    canvas.drawCircle(
      Offset(size.width * cloud3X + 150, size.height * 0.5),
      150,
      paint,
    );

    // Paleta para el cuarto círculo
    final Color cloud4Color;
    if (dayProgress < 0.5) {
      cloud4Color =
          Color.lerp(
            const Color.fromARGB(132, 255, 215, 0), // Amanecer
            const Color.fromARGB(
              132,
              230,
              248,
              26,
            ), // Mediodía: amarillo verdoso
            dayProgress * 2,
          ) ??
          const Color.fromARGB(132, 230, 248, 26);
    } else if (dayProgress < 0.75) {
      cloud4Color =
          Color.lerp(
            const Color.fromARGB(
              132,
              230,
              248,
              26,
            ), // Mediodía: amarillo verdoso
            const Color.fromARGB(132, 156, 66, 50), // Atardecer
            (dayProgress - 0.5) * 4,
          ) ??
          const Color.fromARGB(132, 230, 248, 26);
    } else {
      cloud4Color =
          Color.lerp(
            const Color.fromARGB(132, 255, 99, 71), // Atardecer
            const Color.fromARGB(118, 238, 250, 75), // Noche
            (dayProgress - 0.75) * 4,
          ) ??
          const Color.fromARGB(132, 72, 61, 139);
    }

    paint.color = cloud4Color;
    canvas.drawCircle(
      Offset(size.width * cloud1X * 2, size.height * 0.9),
      200,
      paint,
    );

    // Paleta para la línea
    final Color lineColor;
    if (dayProgress < 0.5) {
      lineColor =
          Color.lerp(
            const Color.fromARGB(146, 139, 69, 19), // Amanecer
            const Color.fromARGB(146, 60, 255, 0), // Mediodía
            dayProgress * 2,
          ) ??
          const Color.fromARGB(146, 60, 255, 0);
    } else if (dayProgress < 0.75) {
      lineColor =
          Color.lerp(
            const Color.fromARGB(146, 60, 255, 0), // Mediodía
            const Color.fromARGB(146, 178, 34, 34), // Atardecer
            (dayProgress - 0.5) * 4,
          ) ??
          const Color.fromARGB(146, 60, 255, 0);
    } else {
      lineColor =
          Color.lerp(
            const Color.fromARGB(146, 255, 0, 0), // Atardecer
            const Color.fromARGB(92, 186, 189, 14), // Noche
            (dayProgress - 0.75) * 4,
          ) ??
          const Color.fromARGB(146, 0, 0, 205);
    }

    paint.color = lineColor;
    paint.strokeWidth = 100;
    canvas.drawLine(
      Offset(size.width - 600, size.height - 50),
      Offset(size.width, size.height - 50),
      paint,
    );
  }

  @override
  bool shouldRepaint(CloudyBakcgroundPainter oldDelegate) {
    return cloud1X != oldDelegate.cloud1X ||
        cloud2X != oldDelegate.cloud2X ||
        cloud3X != oldDelegate.cloud3X ||
        dayProgress != oldDelegate.dayProgress;
  }
}

class SunPathPainter extends CustomPainter {
  final double progress;

  SunPathPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final paintCurve = Paint()
      ..color = Colors.orange
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final paintSun = Paint()
      ..color = Colors.yellow
      ..style = PaintingStyle.fill;

    final path = Path();

    //Calcular la curva
    final p0 = Offset(0, size.height);
    final p1 = Offset(
      size.width / 2,
      size.height * 0.3,
    ); // control point (más bajo que 0)
    final p2 = Offset(size.width, size.height);

    // Posición del sol sobre la curva
    path.moveTo(p0.dx, p0.dy);
    path.quadraticBezierTo(p1.dx, p1.dy, p2.dx, p2.dy);
    canvas.drawPath(path, paintCurve);
    final sunPosition = _calculateY(progress, p0, p1, p2);

    //Dibujar al sol
    canvas.drawCircle(sunPosition, 10, paintSun);
  }

  Offset _calculateY(double t, Offset p0, Offset p1, Offset p2) {
    final x =
        (1 - t) * (1 - t) * p0.dx + 2 * (1 - t) * t * p1.dx + t * t * p2.dx;

    final y =
        (1 - t) * (1 - t) * p0.dy + 2 * (1 - t) * t * p1.dy + t * t * p2.dy;

    return Offset(x, y);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}
