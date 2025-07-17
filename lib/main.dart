// ignore_for_file: unused_local_variable, unused_field

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weather_icons/weather_icons.dart';
import 'package:workmanager/workmanager.dart';
import 'update_handler.dart';
import 'metar_weather_api.dart';
import 'notifications.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:location/location.dart' as loc;
import 'package:url_launcher/url_launcher.dart';

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

@pragma("vm:entry-point")
void notificationsCallback() {
  Workmanager().executeTask((taskName, inputdata) async {
    debugPrint("Ejecutando tarea en background: $taskName");
    try {
      final notificationsService = NotificationsService();
      await notificationsService.showInstantNotificationBackground();
      debugPrint("Tarea $taskName ejecutada exitosamente");
    } catch (e) {
      debugPrint("Error en tarea $taskName: $e");
    }
    return Future.value(true);
  });
}

// Función auxiliar para calcular el retardo inicial hasta la próxima hora deseada
Duration _calculateInitialDelay(int hour, int minute) {
  final now = DateTime.now();
  DateTime nextRun = DateTime(now.year, now.month, now.day, hour, minute);
  if (nextRun.isBefore(now)) {
    nextRun = nextRun.add(
      Duration(days: 1),
    ); // Si la hora ya pasó hoy, programar para mañana
  }
  return nextRun.difference(now);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await FlutterDownloader.initialize(debug: false);
  FlutterDownloader.registerCallback(downloadCallback);
  await initializeDateFormatting("es", null);

  //Inicializamos las notificaciones y el Workmanager para la tarea de notificaciones en segundo plano
  await NotificationsService().init();
  Workmanager().initialize(notificationsCallback, isInDebugMode: true);

  Workmanager().cancelAll();
  //Workmanager().registerPeriodicTask(
  //  "TareaForecastMañana",
  //  "forecastMañana",
  //  frequency: Duration(hours: 24), //cada 24 horas
  //  initialDelay: _calculateInitialDelay(7, 0), //Se ejcuta a las 7 am
  //  constraints: Constraints(
  //    networkType: NetworkType.connected,
  //    requiresBatteryNotLow: false,
  //  ), //Necesita internet
  //);
  //Workmanager().registerPeriodicTask(
  //  "TareaForecastTarde",
  //  "forecastTarde",
  //  frequency: Duration(hours: 24), //cada 24 horas
  //  initialDelay: _calculateInitialDelay(15, 0), //Se ejcuta a las 3 pm
  //  constraints: Constraints(
  //    networkType: NetworkType.connected,
  //    requiresBatteryNotLow: false,
  //  ), //Necesita internet
  //);
  //Workmanager().registerPeriodicTask(
  // "TareaForecastNoche",
  //  "forecastNoche",
  //  frequency: Duration(hours: 24), //cada 24 horas
  //  initialDelay: _calculateInitialDelay(23, 0), //Se ejcuta a las 11 pm
  //  constraints: Constraints(
  //    networkType: NetworkType.connected,
  //    requiresBatteryNotLow: false,
  //  ), //Necesita internet
  //);

  //Workmanager().registerOneOffTask(
  //  "TareaForecastMañana_DEBUG",
  //  "forecastMañana",
  //  initialDelay: Duration(seconds: 10),
  //  constraints: Constraints(networkType: NetworkType.connected),
  //);

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

  Future<void> checkLocationPermissions() async {
    bool serviceEnabled;
    LocationPermission permission;

    var locationService = loc.Location();
    loc.PermissionStatus permissionGranted;
    loc.LocationData locationData;

    try {
      permissionGranted = await locationService.hasPermission();

      serviceEnabled = await locationService.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await locationService.requestService();
        if (!serviceEnabled) {
          return;
        }
      }

      if (permissionGranted == loc.PermissionStatus.denied) {
        permissionGranted = await locationService.requestPermission();
        if (permissionGranted == loc.PermissionStatus.denied) {
          appPermission = false;
          throw Exception("No se han concedido los permisos de ubicación.");
        }
      }
      if (permissionGranted == loc.PermissionStatus.deniedForever) {
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
      debugPrint("No hay conexión a internet.");
      emitEvent({"error": "Error desconocido al verificar la conexión."});
    }
  }
}

enum DayPhase { dawn, morning, noon, afternoon, sunset, night }

DayPhase getDayPhase(double progress) {
  if (progress <= 0.2) {
    return DayPhase.dawn;
  }
  if (progress <= 0.5) {
    return DayPhase.morning;
  }
  if (progress < 0.625) {
    return DayPhase.noon;
  }
  if (progress < 0.75) {
    return DayPhase.afternoon;
  }
  if (progress < 0.875) {
    return DayPhase.sunset;
  }
  return DayPhase.night;
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
  String _testing = "";
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAsyncStuff();
    });
    _timer = Timer.periodic(const Duration(minutes: 1), (timer) {
      setState(() {
        _updateDayProgressAndColors();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _initAsyncStuff() async {
    final checkers = context.read<Checkers>();
    final newWeatherService = context.read<WeatherService>();

    checkers.eventStream.listen((event) {
      debugPrint("Recibiendo evento.");
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

    try {
      await checkers.checkLocationPermissions();
      await checkers.checkInternet();
      await Future.wait([
        newWeatherService.getPosition(),
        newWeatherService.loadStation(),
      ]);
      await newWeatherService.findNerbyStation();
      await Future.wait([
        newWeatherService.getForecast(),
        newWeatherService.fetchMetarData(),
        newWeatherService.getICA(),
      ]);
    } catch (e) {
      debugPrint("Error en _initAsyncStuff: $e");
    }

    final update = UpdateScreenState();
    update.checkForUpdates();
    bool _dialogShown = false;

    update.eventStream.listen((event) {
      debugPrint("Cargando evento: $event");
      if (event.keys.first == "show_update_dialog") {
        showDialog(
          // ignore: use_build_context_synchronously
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
              double progress = 0.5;

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
  }

  Color applyWeatherTimeToTexts(Color textColor, int weatherCode) {
    Color overlay;
    if ((weatherCode >= 51 && weatherCode <= 67) ||
        (weatherCode >= 80 && weatherCode <= 99)) {
      //Lluvias, aguanieve o tormentas
      overlay = const Color.fromARGB(255, 255, 255, 255);
    } else {
      //despejado
      return textColor;
    }

    final blendColor = Color.lerp(textColor, overlay, 0.5);
    final tintedColor = Color.fromARGB(
      ((textColor.a * 255.0).round() & 0xff),
      ((blendColor!.r * 255.0).round() & 0xff),
      ((blendColor.g * 255.0).round() & 0xff),
      ((blendColor.b * 255.0).round() & 0xff),
    );

    return tintedColor;
  }

  Future<void> _updateDayProgressAndColors() async {
    final forecastData = context.read<WeatherService>().forecastCachedData;
    final metardata = context.read<WeatherService>().metarCacheData;
    final cloudDescription = context.read<WeatherService>().cloudDescription;
    _testing = "Funcionando ${DateTime.now()}";
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "DaylightDurationCached";
    final cachedData = prefs.getString(cacheKey);
    Map? cachedLightStates;

    //Valores por defecto
    double dayProgress = 0.0;
    var sunrise = DateTime.now().toLocal();
    var sunset = DateTime.now().add(const Duration(hours: 12)).toLocal();
    int? daylightDurationMin;
    bool isNight = true;
    final now = DateTime.now();
    int weatherCode = 0;
    double testProgress = 1.0;

    if (cachedData != null) {
      //Verificar si hay datos en la memoria caché
      final data = jsonDecode(cachedData);
      final timeStamp = data["timeStamp"] ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - timeStamp <
          4320 * 60 * 1000) {
        cachedLightStates = data;
      }
      //convertimos los datos a un objeto DateTime
      var sunriseCached = DateTime.fromMillisecondsSinceEpoch(
        cachedLightStates!["sunriseTimestamp"],
      ).toLocal();
      var sunsetCached = DateTime.fromMillisecondsSinceEpoch(
        cachedLightStates["sunsetTimestamp"],
      ).toLocal();

      sunrise = DateTime(
        now.year,
        now.month,
        now.day,
        sunriseCached.hour,
        sunriseCached.minute,
        sunriseCached.second,
      );

      sunset = DateTime(
        now.year,
        now.month,
        now.day,
        sunsetCached.hour,
        sunsetCached.minute,
        sunsetCached.second,
      );

      final totalDuration = cachedLightStates["totalDuration"];
      isNight = now.isBefore(sunrise) || now.isAfter(sunset);

      final currentDuration = now.difference(sunrise).inMinutes;
      dayProgress = totalDuration > 0 ? currentDuration / totalDuration : 0.0;

      debugPrint("Total duration : $sunrise");
    } else if (forecastData != null &&
        forecastData.isNotEmpty &&
        cloudDescription.isNotEmpty) {
      try {
        sunrise = DateTime.parse(forecastData["dailySunrise"]).toLocal();
        sunset = DateTime.parse(forecastData["dailySunset"]).toLocal();
        final daylightDurationSeconds =
            forecastData["dailyDaylightDuration"][0];
        final totalDuration = (daylightDurationSeconds / 60).round();
        final currentDuration = now.difference(sunrise).inMinutes;
        isNight = now.isBefore(sunrise) || now.isAfter(sunset);
        dayProgress = totalDuration > 0 ? currentDuration / totalDuration : 0.0;

        // Guardar en caché datos reales
        cachedLightStates = {
          "sunriseTimestamp": sunrise.millisecondsSinceEpoch,
          "sunsetTimestamp": sunset.millisecondsSinceEpoch,
          "totalDuration": totalDuration,
          "timeStamp": DateTime.now().millisecondsSinceEpoch,
        };
        final success = await prefs.setString(
          cacheKey,
          json.encode(cachedLightStates),
        );
        debugPrint("¿Guardado el progreso del día en caché?: $success");
      } catch (e) {
        debugPrint("Error parseando datos reales: $e");
      }
    } else {
      // Usar por defecto SIN GUARDAR EN CACHÉ
      sunrise = DateTime(now.year, now.month, now.day, 6, 0);
      sunset = DateTime(now.year, now.month, now.day, 18, 0);
      isNight = now.isBefore(sunrise) || now.isAfter(sunset);
      final totalDuration = sunset.difference(sunrise).inMinutes;
      final currentDuration = now.difference(sunrise).inMinutes;
      dayProgress = totalDuration > 0 ? currentDuration / totalDuration : 0.0;

      debugPrint("Usando valores por defecto (no se guardarán)");
    }

    debugPrint("El sunrise actual es $sunrise");

    if ((dayProgress - _dayProgress).abs() > 0.01) {
      _dayProgress = dayProgress;
    }

    debugPrint("Progreso del día: $dayProgress");

    // Interpolación de colores para mainColor
    final dayPhase = getDayPhase(_dayProgress);
    switch (dayPhase) {
      case DayPhase.dawn:
        _mainColor =
            Color.lerp(
              const Color.fromARGB(255, 204, 183, 192),
              const Color.fromARGB(255, 173, 203, 243),
              _dayProgress * 5,
            ) ??
            const Color.fromARGB(255, 52, 85, 85);

        _titleTextColor =
            Color.lerp(
              const Color.fromARGB(255, 255, 168, 255),
              const Color.fromARGB(255, 255, 226, 108),
              _dayProgress * 4,
            ) ??
            const Color.fromARGB(255, 255, 215, 0);

        _secondaryColor =
            Color.lerp(
              const Color.fromARGB(115, 208, 142, 223),
              const Color.fromARGB(115, 10, 10, 70),
              _dayProgress * 4,
            ) ??
            const Color.fromARGB(115, 25, 25, 112);
        break;

      case DayPhase.morning:
        _mainColor =
            Color.lerp(
              const Color.fromARGB(255, 39, 95, 163),
              const Color.fromARGB(255, 21, 97, 122),
              (_dayProgress - 0.2) * 4,
            ) ??
            const Color.fromARGB(255, 0, 128, 128);

        _titleTextColor =
            Color.lerp(
              const Color.fromARGB(255, 255, 226, 108),
              const Color.fromARGB(255, 255, 240, 35),
              (_dayProgress - 0.25) * 4,
            ) ??
            const Color.fromARGB(255, 255, 215, 0);

        _secondaryColor =
            Color.lerp(
              const Color.fromARGB(115, 12, 23, 124),
              const Color.fromARGB(115, 5, 125, 223),
              (_dayProgress - 0.25) * 4,
            ) ??
            const Color.fromARGB(115, 25, 25, 112);
        break;

      case DayPhase.noon:
        _mainColor =
            Color.lerp(
              const Color.fromARGB(255, 37, 106, 131),
              const Color.fromARGB(255, 12, 53, 124),
              (_dayProgress - 0.5) * 5,
            ) ??
            const Color.fromARGB(255, 0, 128, 128);

        _titleTextColor =
            Color.lerp(
              const Color.fromARGB(207, 255, 217, 0),
              const Color.fromARGB(255, 252, 219, 37),
              (_dayProgress - 0.5) * 8,
            ) ??
            const Color.fromARGB(255, 0, 128, 128);

        _secondaryColor =
            Color.lerp(
              const Color.fromARGB(115, 12, 23, 124),
              const Color.fromARGB(115, 25, 162, 216),
              (_dayProgress - 0.5) * 8,
            ) ??
            const Color.fromARGB(255, 0, 128, 128);
        break;

      case DayPhase.afternoon:
        _mainColor =
            Color.lerp(
              const Color.fromARGB(255, 23, 91, 209),
              const Color.fromARGB(255, 250, 96, 68),
              (_dayProgress - 0.625) * 4,
            ) ??
            const Color.fromARGB(255, 0, 128, 128);

        _titleTextColor =
            Color.lerp(
              const Color.fromARGB(255, 216, 189, 34),
              const Color.fromARGB(255, 250, 239, 140),
              (_dayProgress - 0.5) * 4,
            ) ??
            const Color.fromARGB(255, 255, 215, 0);

        _secondaryColor =
            Color.lerp(
              const Color.fromARGB(115, 25, 25, 112),
              const Color.fromARGB(115, 97, 179, 211),
              (_dayProgress - 0.5) * 4,
            ) ??
            const Color.fromARGB(115, 25, 25, 112);
        break;

      case DayPhase.sunset:
        _mainColor =
            Color.lerp(
              const Color.fromARGB(255, 245, 128, 45),
              const Color.fromARGB(255, 203, 203, 250),
              (_dayProgress - 0.75) * 8,
            ) ??
            const Color.fromARGB(255, 100, 100, 160);

        _titleTextColor =
            Color.lerp(
              const Color.fromARGB(255, 253, 165, 149),
              const Color.fromARGB(255, 200, 200, 255),
              (_dayProgress - 0.75) * 8,
            ) ??
            const Color.fromARGB(255, 100, 100, 160);

        _secondaryColor =
            Color.lerp(
              const Color.fromARGB(115, 139, 150, 136),
              const Color.fromARGB(115, 199, 199, 172),
              (_dayProgress - 0.75) * 8,
            ) ??
            const Color.fromARGB(115, 100, 100, 160);
        break;

      case DayPhase.night:
        _mainColor =
            Color.lerp(
              const Color.fromARGB(255, 255, 238, 227),
              const Color.fromARGB(255, 231, 231, 250),
              (_dayProgress - 0.875) * 4,
            ) ??
            const Color.fromARGB(255, 100, 100, 160);

        _titleTextColor =
            Color.lerp(
              const Color.fromARGB(255, 255, 187, 174),
              const Color.fromARGB(255, 226, 226, 255),
              (_dayProgress - 0.75) * 4,
            ) ??
            const Color.fromARGB(255, 200, 200, 255);

        _secondaryColor =
            Color.lerp(
              const Color.fromARGB(115, 115, 87, 87),
              const Color.fromARGB(115, 120, 120, 180),
              (_dayProgress - 0.75) * 4,
            ) ??
            const Color.fromARGB(115, 120, 120, 180);
        break;
    }

    _titleTextColor = applyWeatherTimeToTexts(_titleTextColor, weatherCode);
    _mainColor = applyWeatherTimeToTexts(_mainColor, weatherCode);
    _secondaryColor = applyWeatherTimeToTexts(_secondaryColor, weatherCode);
  }

  Future<void> _launchUrl() async {
    final Uri url = Uri.parse("https://buymeacoffee.com/ukory");
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw Exception("No se pudo lanzar la URL");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<WeatherService>(
      builder: (context, weatherService, child) {
        _updateDayProgressAndColors();
        final metarData = weatherService.metarCacheData;
        final forecastData = weatherService.forecastCachedData;
        var weatherCode = metarData?["weather_code"] ?? 0;
        var cloudCover = metarData?["cloudCover"] ?? 0;
        //final testWeatherCode = 99;
        //final testCloudCover = 100;
        //weatherCode = testWeatherCode;
        //cloudCover = testCloudCover;
        if (metarData == null ||
            metarData.isEmpty ||
            forecastData == null ||
            forecastData.isEmpty) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: MovingCloudsBackground(
              weatherCode: weatherCode,
              cloudCover: (cloudCover as num).toDouble(),
              dynamicWeather: DynamicWeather(weatherCode: weatherCode),
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

        final newWeatherApi = context.read<WeatherService>();
        var temp = metarData["temperature"].toString();
        var separatedTemp = temp.split(".");
        var tempByHours = forecastData["tempByHours"];
        var hours = forecastData["tempHours"];
        var dates = forecastData["dates"];
        var precipitation = forecastData["precipitationByHours"];
        var sunrise = DateTime.parse(forecastData["dailySunrise"]);
        var sunset = DateTime.parse(forecastData["dailySunset"]);

        return Scaffold(
          floatingActionButton: FloatingActionButton(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                30,
              ), // o 0 para que sea cuadrado
            ),

            tooltip: "Invitame un café!",
            backgroundColor: _titleTextColor,
            onPressed: () async {
              _launchUrl();
            },
            child: Icon(Icons.coffee, color: Colors.black87),
          ),
          backgroundColor: Colors.transparent,
          body: MovingCloudsBackground(
            weatherCode: weatherCode,
            cloudCover: (cloudCover as num).toDouble(),
            dynamicWeather: DynamicWeather(weatherCode: weatherCode),
            dayProgress: _dayProgress,
            child: RefreshIndicator(
              color: _titleTextColor,
              backgroundColor: _mainColor,
              displacement: 0.0,
              edgeOffset: 0,
              onRefresh: () async {
                await newWeatherApi.getPrecisePositionLocationMethod().then((
                  _,
                ) {
                  newWeatherApi.findNerbyStation();
                  newWeatherApi.getForecast();
                  newWeatherApi.fetchMetarData();
                  newWeatherApi.getICA();
                  setState(() {
                    _updateDayProgressAndColors();
                  });
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
    required this.titleTextColor,
    required this.separatedTemp,
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
  late final List<String> separatedTemp;
  late final List<double> tempByHours;
  late final List<int> hours;
  late final List<DateTime> dates;
  late final List<double> precipitation;
  late final double dayProgress;
  late final DateTime sunrise;
  late final DateTime sunset;
  late List<FlSpot> spots;

  @override
  void initState() {
    super.initState();
    weatherState = widget.weatherState;
    separatedTemp = widget.separatedTemp;
    tempByHours = widget.tempByHours;
    hours = widget.hours;
    dates = widget.dates;
    precipitation = widget.precipitation;
    dayProgress = widget.dayProgress;
    sunrise = widget.sunrise;
    sunset = widget.sunset;
    _updateSpots();
  }

  @override
  void didUpdateWidget(covariant IndexPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tempByHours != oldWidget.tempByHours ||
        widget.hours != oldWidget.hours) {
      setState(() {
        _updateSpots();
      });
    }
  }

  void _updateSpots() {
    spots = List.generate(
      widget.hours.length,
      (i) => FlSpot(i.toDouble(), widget.tempByHours[i]),
    );
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
    var intigerPart = widget.separatedTemp[0];
    final linechartbardata = LineChartBarData(
      show: true,
      spots: spots,
      gradient: LinearGradient(
        colors: [widget.mainColor, widget.mainColor, widget.mainColor],
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
                color: widget.titleTextColor,
              );
            },
      ),
    );

    return LayoutBuilder(
      builder: (context, constraits) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  weatherState.siteName,
                  style: TextStyle(fontSize: 30, color: widget.mainColor),
                ),
                Row(
                  spacing: 0,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (int i = 0; i < intigerPart.length; i++)
                      Flexible(
                        child: AnimatedSwitcher(
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
                              fontSize: 100,
                              color: widget.titleTextColor,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                          ),
                        ),
                      ),
                    Flexible(
                      child: Text(
                        ".",
                        style: GoogleFonts.kanit(
                          fontSize: 90,
                          color: widget.titleTextColor,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                      ),
                    ),
                    Flexible(
                      child: AnimatedSwitcher(
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
                          key: ValueKey(
                            separatedTemp.isNotEmpty ? separatedTemp[1] : 0,
                          ),
                          padding: const EdgeInsets.only(top: 0),
                          child: Text(
                            "${separatedTemp.isNotEmpty ? separatedTemp[1][0] : 0}",
                            style: GoogleFonts.kanit(
                              fontSize: 90,
                              color: widget.titleTextColor,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 2,
                          ),
                        ),
                      ),
                    ),
                    Text(
                      "C°",
                      style: GoogleFonts.kanit(
                        fontSize: 90,
                        color: widget.titleTextColor,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.visible,
                    ),
                  ],
                ),
              ],
            ),
            Flexible(
              child: Text(
                "↑${weatherState.forecastCachedData!["maxTemp"]}°/↓${weatherState.forecastCachedData!["minTemp"]}°",
                style: GoogleFonts.kanit(
                  fontSize: 27,
                  color: widget.mainColor,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ),
            Flexible(
              child: Text(
                "Sensación térmica: ${weatherState.metarCacheData!["heatIndex"]} °C",
                style: GoogleFonts.kanit(
                  fontSize: 27,
                  color: widget.mainColor,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ),
            Container(
              margin: EdgeInsets.only(top: 20, left: 20, right: 20),
              child: Card(
                elevation: 4,
                clipBehavior: Clip.none,
                color: widget.secondaryColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadiusGeometry.all(Radius.circular(10)),
                ),
                child: Column(
                  children: [
                    tempByHours.isEmpty && hours.isEmpty
                        ? Center(
                            child: SizedBox(
                              width: 100,
                              height: 200,
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: widget.mainColor,
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
                                Flexible(
                                  child: Text(
                                    "Cielo ${weatherState.cloudDescription.keys.first} ",
                                    style: GoogleFonts.kanit(
                                      fontSize: 20,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w300,
                                    ),
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
                                          final temp = barSpot.y
                                              .toStringAsFixed(
                                                1,
                                              ); // temperatura
                                          final precip =
                                              precipitation[barSpot.spotIndex]
                                                  .toInt(); // precipitación

                                          return LineTooltipItem(
                                            "$hour H\n $temp°C\n☔ $precip%",
                                            GoogleFonts.kanit(
                                              color: Colors.white,
                                            ),
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
              elevation: 4,
              color: widget.secondaryColor,
              child: SizedBox(
                height: 145,
                width: constraits.maxWidth - 50,
                child: Padding(
                  padding: EdgeInsetsGeometry.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Flexible(
                              child: Row(
                                children: [
                                  Text(
                                    "ICA ",
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const Icon(
                                    WeatherIcons.windy,
                                    color: Colors.white,
                                    size: 15,
                                  ),
                                ],
                              ),
                            ),

                            Text(
                              _getICAMessages(
                                weatherState.icaCache!["icaFinal"] ?? 0,
                              ).values.first,
                              style: GoogleFonts.kanit(
                                fontSize: 15,
                                color: Colors.white,
                              ),
                              softWrap: true,
                              overflow: TextOverflow.visible,
                            ),

                            Flexible(
                              child: Text(
                                "${_getICAMessages(weatherState.icaCache!["icaFinal"] ?? 0).keys.first} (${weatherState.icaCache!["icaFinal"] ?? 0})",
                                style: GoogleFonts.kanit(
                                  fontSize: 20,
                                  color: Colors.white,
                                ),
                              ),
                            ),

                            Flexible(
                              child: SizedBox(
                                height: 10,
                                width: 190,
                                child: LinearProgressIndicator(
                                  borderRadius: BorderRadius.all(
                                    Radius.circular(600),
                                  ),
                                  backgroundColor: widget.mainColor,
                                  value:
                                      ((weatherState.icaCache!["icaFinal"] ??
                                              0 * 100 / 100) ??
                                          0) /
                                      500,
                                  color: _getColor(
                                    ((weatherState.icaCache!["icaFinal"] ??
                                                0 * 100 / 100) ??
                                            0) /
                                        500,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: Icon(
                          _getICAIcons(weatherState.icaCache!["icaFinal"] ?? 0),
                          size: 50,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            WeekForecast(widget: widget, weatherState: weatherState),
            Cards(
              weatherState: weatherState,
              mainColor: widget.mainColor,
              secondaryColor: widget.secondaryColor,
              titleTextColor: widget.titleTextColor,
            ),
            SunCurve(
              progress: widget.dayProgress,
              sunrise: sunrise,
              sunset: sunset,
              mainColor: widget.mainColor,
              secondaryColor: widget.secondaryColor,
              titleTextColor: widget.titleTextColor,
            ),
          ],
        );
      },
    );
  }
}

class WeekForecast extends StatelessWidget {
  const WeekForecast({
    super.key,
    required this.widget,
    required this.weatherState,
  });

  final IndexPage widget;
  final WeatherService weatherState;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraits) {
        return Card(
          elevation: 4,
          color: widget.secondaryColor,
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: SizedBox(
              width: constraits.maxWidth - 80,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(
                  weatherState.forecastCachedData!["weekDays"].length,
                  (index) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            flex: 2,
                            child: Text(
                              weatherState
                                  .forecastCachedData!["weekDays"][index],
                              style: GoogleFonts.kanit(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                              textAlign: TextAlign.left,
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              spacing: 0,
                              children: [
                                Text(
                                  "${weatherState.forecastCachedData!["daysPrecipitationTotals"][index]}%  ",
                                  style: GoogleFonts.kanit(
                                    color: Colors.white,
                                    fontSize: 14,
                                  ),
                                ),
                                Icon(
                                  WeatherIcons.raindrop,
                                  color: widget.titleTextColor,
                                  size: 15,
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  "↑ ${(weatherState.forecastCachedData!["daysMaxTemps"][index] as num).toInt()}°",
                                  style: GoogleFonts.kanit(
                                    color: Colors.white,
                                    fontSize: 14,
                                  ),
                                ),
                                Text(
                                  "↓ ${(weatherState.forecastCachedData!["daysMinTemps"][index] as num).toInt()}°",
                                  style: GoogleFonts.kanit(
                                    color: Colors.white,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class SunCurve extends StatefulWidget {
  const SunCurve({
    super.key,
    required this.progress,
    required this.sunset,
    required this.sunrise,
    required this.mainColor,
    required this.secondaryColor,
    required this.titleTextColor,
  });

  final double progress;
  final DateTime sunset;
  final DateTime sunrise;
  final mainColor;
  final secondaryColor;
  final titleTextColor;

  @override
  State<SunCurve> createState() => _SunCurveState();
}

class _SunCurveState extends State<SunCurve> {
  late Color secondaryColor;
  late DateTime sunset;
  late DateTime sunrise;
  late double progress;

  @override
  void initState() {
    super.initState();
    secondaryColor = widget.secondaryColor;
    sunset = widget.sunset;
    sunrise = widget.sunrise;
    progress = widget.progress;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraits) {
        final double availableWith = constraits.maxWidth;
        return Padding(
          padding: EdgeInsetsGeometry.only(bottom: 100),
          child: Card(
            elevation: 4,
            color: widget.secondaryColor,
            child: SizedBox(
              height: 200,
              width: availableWith - 50,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 300,
                    height: 120,
                    child: SunPath(dayProgress: widget.progress),
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
      },
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
                elevation: 4,
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
  Cards({
    super.key,
    required this.weatherState,
    required this.mainColor,
    required this.secondaryColor,
    required this.titleTextColor,
  });

  final mainColor;
  final secondaryColor;
  final titleTextColor;
  final cardPadding = EdgeInsets.all(15);
  final WeatherService weatherState;
  double fontCardSize = 18.0;

  Map<String, String> _getuvmessage(double uvIndex) {
    if (uvIndex >= 1.1) {
      return {"Extremo!": "¡Peligro! Quédate en interiores"};
    } else if (uvIndex >= 0.8) {
      return {"Demasiado alto": "Evita la exposición al sol"};
    } else if (uvIndex >= 0.6) {
      return {"Muy alto": "Minimiza la exposición al sol"};
    } else if (uvIndex >= 0.3) {
      return {"Alto": "Poca precaución necesaria"};
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
            "Tiempo inestable o severo, con vientos fuertes o tormentas",
      };
    } else {
      return {"Error": "Datos no disponibles"};
    }
  }

  Map<String, String> _getPrecipitationMessage(double precipitationMm) {
    if (precipitationMm > 20.0) {
      return {"Lluvia Extrema": "Posibles inundaciones. Conducción peligrosa"};
    } else if (precipitationMm > 8.0) {
      return {"Lluvia Fuerte": "Es posible lluvias intensas"};
    } else if (precipitationMm > 2.5) {
      return {"Lluvia Moderada": "Posibles lluvias continuas"};
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
      child: LayoutBuilder(
        builder: (context, constraits) {
          final double availableWith = constraits.maxWidth;
          final double minCardWidth = 150;
          int crossAxisCount = (availableWith / minCardWidth).floor();

          if (crossAxisCount == 0) {
            crossAxisCount = 2;
          }

          return GridView.count(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            padding: EdgeInsets.all(20),
            shrinkWrap: true,
            physics: NeverScrollableScrollPhysics(),
            childAspectRatio: (1.5 / crossAxisCount),
            children: [
              Card(
                elevation: 4,
                color: secondaryColor,
                child: Padding(
                  padding: cardPadding,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: Row(
                          children: [
                            Text(
                              "Índice UV ",
                              style: GoogleFonts.kanit(
                                fontSize: 12,
                                color: Colors.white,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            const Icon(
                              Icons.sunny,
                              color: Colors.white,
                              size: 15,
                            ),
                          ],
                        ),
                      ),
                      Text(
                        _getuvmessage(
                          (weatherState
                                      .forecastCachedData!["dailyUVIndexMax"][0] ??
                                  1) /
                              10,
                        ).entries.first.value,
                        style: GoogleFonts.kanit(
                          fontSize: 15,
                          color: Colors.white,
                        ),
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
                              maxLines: 3,
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
                elevation: 4,
                color: secondaryColor,
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
                                border: Border.all(
                                  color: Colors.grey,
                                  width: 10,
                                ),
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
                                  weatherState
                                      .metarCacheData!["widDirection"] ??
                                  0,
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
                color: secondaryColor,
                elevation: 4,
                child: Padding(
                  padding: cardPadding,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: Row(
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
                      ),
                      Expanded(
                        flex: 3,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Text(
                            _getPressureAlertMessage(
                              double.parse(
                                weatherState.metarCacheData!["pressure"] ?? 0,
                              ),
                            ).values.first,
                            style: GoogleFonts.kanit(
                              fontSize: 14,
                              color: Colors.white,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.visible,
                          ),
                        ),
                      ),
                      Column(
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
                              fontSize: fontCardSize - 1,
                              color: Colors.white,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            "${weatherState.metarCacheData!["pressure"]} hPa",
                            style: GoogleFonts.kanit(
                              fontSize: fontCardSize - 2,
                              color: Colors.white,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
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
                              color: titleTextColor,
                              backgroundColor: mainColor,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              Card(
                color: secondaryColor,
                elevation: 4,
                child: Padding(
                  padding: cardPadding,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Row(
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
                      ),

                      Expanded(
                        flex: 2,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Text(
                            _getPrecipitationMessage(
                              weatherState
                                  .forecastCachedData!["precipitationByHours"][0],
                            ).values.first,
                            style: GoogleFonts.kanit(
                              fontSize: 15,
                              color: Colors.white,
                              fontWeight: FontWeight.w400,
                              height: 1.3, // Espaciado entre líneas
                            ),
                            softWrap: true,
                            overflow: TextOverflow.fade,
                            textAlign: TextAlign.start,
                          ),
                        ),
                      ),

                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                    ],
                  ),
                ),
              ),

              Card(
                color: secondaryColor,
                elevation: 4,
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
                color: secondaryColor,
                elevation: 4,
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

                      Padding(
                        padding: EdgeInsetsGeometry.only(top: 6),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.start,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _getHumidityMessage(
                                (weatherState.metarCacheData!["humidity"] ?? 1),
                              ).values.first,
                              style: GoogleFonts.kanit(
                                fontSize: 17,
                                color: Colors.white,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            SizedBox(height: 4),
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
                                color: titleTextColor,
                                backgroundColor: mainColor,
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
          );
        },
      ),
    );
  }
}

class MovingCloudsBackground extends StatefulWidget {
  final Widget child;
  final Widget dynamicWeather;
  final double dayProgress;
  final double cloudCover;
  final int weatherCode;
  const MovingCloudsBackground({
    super.key,
    required this.child,
    required this.dayProgress,
    required this.dynamicWeather,
    required this.cloudCover,
    required this.weatherCode,
  });

  @override
  _MovingCloudsBackgroundState createState() => _MovingCloudsBackgroundState();
}

class _MovingCloudsBackgroundState extends State<MovingCloudsBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late double dayProgress;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: Duration(seconds: 50),
    )..repeat();
    dayProgress = widget.dayProgress;
  }

  @override
  void didUpdateWidget(MovingCloudsBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dayProgress != widget.dayProgress) {
      setState(() {
        dayProgress = widget.dayProgress;
      });
    }
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
            cloudCover: widget.cloudCover,
            weathercode: widget.weatherCode,
            dayProgress: widget.dayProgress,
            cloud1X: 0.2 + 0.1 * sin(2 * pi * _controller.value),
            cloud2X: 0.41 + 0.11 * sin(5 * pi * _controller.value),
            cloud3X: 0.21 + 0.33 * sin(5 * pi * _controller.value),
          ),

          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(child: widget.dynamicWeather),
              ),
              widget.child,
            ],
          ),
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
    required this.cloudCover,
    required this.weathercode,
  });

  final double cloud1X;
  final double cloud2X;
  final double cloud3X;
  double dayProgress;
  final double cloudCover;
  final int weathercode;

  LinearGradient applyWeatherTimeToBackground(
    LinearGradient basebackground,
    int weatherCode,
  ) {
    Color overlay;
    if ((weatherCode >= 51 && weatherCode <= 67) ||
        (weatherCode >= 80 && weatherCode <= 99)) {
      //Lluvias, aguanieve o tormentas
      overlay = const Color.fromARGB(178, 85, 85, 85);
    } else {
      //despejado
      return basebackground;
    }

    List<Color> tintedColors = basebackground.colors.map((color) {
      return Color.alphaBlend(overlay, color);
    }).toList();

    return LinearGradient(
      begin: basebackground.begin,
      end: basebackground.end,
      colors: tintedColors,
      stops: basebackground.stops,
    );
  }

  Color applyWeatherTimeToclouds(Color cloudColor, int weatherCode) {
    Color overlay;
    if ((weatherCode >= 51 && weatherCode <= 67) ||
        (weatherCode >= 80 && weatherCode <= 99)) {
      //Lluvias, aguanieve o tormentas
      overlay = const Color.fromARGB(177, 133, 133, 133);
    } else {
      //despejado
      return cloudColor;
    }

    Color tintedColor = Color.alphaBlend(cloudColor, overlay);

    return tintedColor;
  }

  void paintDynamicClouds(
    Canvas canvas,
    Size size,
    Paint paint,
    double cloudCover,
    List<Offset> baseOffsets,
    Color baseColor,
  ) {
    final int cloudCount = (cloudCover * 8).toInt();
    final Random random = Random(42);
    final double minSize = 190;
    final double maxSize = 230;

    for (int i = 0; i < cloudCount; i++) {
      final offset = baseOffsets[i % baseOffsets.length];

      final dx = offset.dx + (random.nextDouble() - 0.5) * 0.2;
      final dy = offset.dy + (random.nextDouble() - 0.5) * 0.1;
      final double radius = lerpDouble(
        minSize,
        maxSize,
        random.nextDouble() * cloudCover,
      )!;
      final double opacity = (0.4 + 0.5 * cloudCover).clamp(0.0, 1.0);
      paint.color = baseColor.withAlpha((opacity * 50).toInt());
      canvas.drawCircle(
        Offset(size.width * dx, size.height * dy),
        radius,
        paint,
      );
    }
  }

  Color cloudColors(double dayProgress) {
    const Color dawn = Color.fromARGB(15, 202, 183, 183); // Amanecer
    const Color noon = Color.fromARGB(234, 255, 255, 255); // Mediodía
    const Color sunset = Color.fromARGB(255, 255, 255, 255); // Atardecer
    const Color night = Color.fromARGB(66, 255, 255, 255); // Noche

    if (dayProgress < 0.5) {
      //Amanecer / Mediodía
      double l = dayProgress / 0.5;
      return Color.lerp(dawn, noon, l)!;
    } else if (dayProgress < 0.75) {
      //Mediodia / Atardecer
      double l = (dayProgress - 0.5) / 0.25;
      return Color.lerp(noon, sunset, l)!;
    } else {
      //Atardecer / Noche
      double l = (dayProgress - 0.75) / 0.25;
      return Color.lerp(sunset, night, l)!;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 40);
    // Fondo dinámico
    final Paint backgroundPaint = Paint();
    LinearGradient backgroundColor;

    if (dayProgress <= 0.2) {
      backgroundColor = LinearGradient.lerp(
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomRight,
          colors: [
            const Color.fromARGB(255, 20, 20, 40), // Noche inicial
            const Color.fromARGB(255, 255, 157, 173), // Rosado amanecer
          ],
          stops: [0.0, 1.0],
        ),
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color.fromARGB(148, 113, 108, 173), // Rosado amanecer
            const Color.fromARGB(255, 165, 220, 252), // Noche inicial
          ],
          stops: [0.0, 1.0],
        ),
        dayProgress / 0.25,
      )!;
    } else if (dayProgress <= 0.5) {
      backgroundColor = LinearGradient.lerp(
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomRight,
          colors: [
            const Color.fromARGB(148, 113, 108, 173), // Rosado amanecer
            const Color.fromARGB(255, 165, 220, 252), // Noche inicial
          ],
          stops: [0.0, 1.0],
        ),
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color.fromARGB(255, 13, 110, 221), // mediodía
            const Color.fromARGB(255, 201, 223, 252),
          ],
          stops: [0.0, 1.0],
        ),
        dayProgress / 0.25,
      )!;
    } else if (dayProgress < 0.675) {
      backgroundColor = LinearGradient.lerp(
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color.fromARGB(255, 62, 122, 199),
            const Color.fromARGB(255, 255, 234, 234),
          ],
          stops: [0.0, 1.0],
        ),
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color.fromARGB(255, 20, 122, 255), // mediodía
            const Color.fromARGB(255, 253, 229, 229),
          ],
          stops: [0.0, 1.0],
        ),
        dayProgress / 0.25,
      )!;
    } else if (dayProgress <= 0.75) {
      backgroundColor = LinearGradient.lerp(
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color.fromARGB(255, 255, 221, 221), //mediodía
            const Color.fromARGB(255, 255, 0, 0),
          ],
          stops: [0.0, 1.0],
        ),
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color.fromARGB(255, 46, 171, 255), // atardecer
            const Color.fromARGB(255, 253, 115, 61),
          ],
          stops: [0.0, 1.0],
        ),
        (dayProgress - 0.25) / 0.25,
      )!;
    } else if (dayProgress <= 0.89) {
      backgroundColor = LinearGradient.lerp(
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color.fromARGB(255, 46, 171, 255), // atardecer
            const Color.fromARGB(255, 253, 115, 61),
          ],
          stops: [0.0, 1.0],
        ),
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color.fromARGB(255, 29, 157, 189), // Atardecer
            const Color.fromARGB(183, 255, 124, 72),
          ],
          stops: [0.0, 1.0],
        ),
        (dayProgress - 0.75) / 0.25,
      )!;
    } else {
      backgroundColor = LinearGradient.lerp(
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color.fromARGB(255, 0, 204, 255), // Atardecer
            const Color.fromARGB(108, 255, 110, 53),
          ],
          stops: [0.0, 1.0],
        ),
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color.fromARGB(255, 10, 10, 30), // Negro
            const Color.fromARGB(255, 5, 5, 15), // Más oscuro
          ],
          stops: [0.0, 1.0],
        ),
        (dayProgress - 0.75) / 0.25,
      )!;
    }

    backgroundColor = applyWeatherTimeToBackground(
      backgroundColor,
      weathercode,
    );

    backgroundPaint.shader = backgroundColor.createShader(
      Rect.fromLTWH(0, 0, size.width, size.height),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      backgroundPaint,
    );

    Color cloud1Color;

    cloud1Color = cloudColors(dayProgress);

    final baseOffsets = [
      Offset(cloud1X, 0.2),
      Offset(cloud2X, 0.3),
      Offset(cloud3X, 0.5),
      Offset(cloud1X * 2, 0.9),
    ];

    final double normalizedCloudCover = (cloudCover / 100.0).clamp(0.0, 1.0);

    cloud1Color = applyWeatherTimeToclouds(cloud1Color, weathercode);

    paintDynamicClouds(
      canvas,
      size,
      paint,
      normalizedCloudCover,
      baseOffsets,
      cloud1Color,
    );

    // Paleta para la línea
    final Color lineColor;
    if (dayProgress < 0.5) {
      lineColor =
          Color.lerp(
            const Color.fromARGB(36, 255, 238, 0), // Amanecer
            const Color.fromARGB(38, 60, 255, 0), // Mediodía
            dayProgress * 2,
          ) ??
          const Color.fromARGB(146, 60, 255, 0);
    } else if (dayProgress < 0.75) {
      lineColor =
          Color.lerp(
            const Color.fromARGB(8, 60, 255, 0), // Mediodía
            const Color.fromARGB(146, 178, 34, 34), // Atardecer
            (dayProgress - 0.5) * 4,
          ) ??
          const Color.fromARGB(146, 60, 255, 0);
    } else {
      lineColor =
          Color.lerp(
            const Color.fromARGB(48, 255, 22, 22), // Atardecer
            const Color.fromARGB(34, 249, 255, 158), // Noche
            (dayProgress - 0.75) * 4,
          ) ??
          const Color.fromARGB(146, 0, 0, 205);
    }

    paint.color = lineColor;
    paint.strokeWidth = 100;
    canvas.drawLine(
      Offset(size.width - 600, size.height),
      Offset(size.width, size.height),
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

class SunPath extends StatefulWidget {
  const SunPath({super.key, required this.dayProgress});
  final double dayProgress;

  @override
  State<SunPath> createState() => _SunPathState();
}

class _SunPathState extends State<SunPath> {
  late double dayProgress;

  @override
  void initState() {
    super.initState();
    dayProgress = widget.dayProgress;
  }

  @override
  void didUpdateWidget(SunPath oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dayProgress != widget.dayProgress) {
      setState(() {
        dayProgress = widget.dayProgress;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: SunPathPainter(widget.dayProgress),
      key: ValueKey(widget.dayProgress),
      size: Size.infinite,
    );
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
  bool shouldRepaint(SunPathPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

enum WeatherEffect { none, rain, snow, hail }

class Particle {
  Offset position;
  double speed;
  double size;
  WeatherEffect effect;

  Particle({
    required this.position,
    required this.speed,
    required this.size,
    required this.effect,
  });
}

class DynamicWeather extends StatefulWidget {
  const DynamicWeather({super.key, required this.weatherCode});
  final int weatherCode;

  @override
  State<DynamicWeather> createState() => _DynamicWeatherState();
}

class _DynamicWeatherState extends State<DynamicWeather>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  List<Particle> _particles = [];
  late WeatherEffect effect;

  @override
  void initState() {
    super.initState();
    effect = determineEffect(widget.weatherCode);
    _controller =
        AnimationController(
            vsync: this,
            duration: const Duration(seconds: 1000),
          )
          ..addListener(updatePartcles)
          ..repeat();
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant DynamicWeather oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.weatherCode != widget.weatherCode) {
      setState(() {
        effect = determineEffect(widget.weatherCode);
        generateParticles();
      });
    }
  }

  WeatherEffect determineEffect(int weatherCode) {
    if (weatherCode >= 71 && weatherCode <= 77 ||
        weatherCode >= 85 && weatherCode <= 86) {
      return WeatherEffect.snow;
    } else if (weatherCode >= 66 && weatherCode <= 67) {
      return WeatherEffect.hail;
    } else if ((weatherCode >= 51 && weatherCode <= 65) ||
        (weatherCode >= 80 && weatherCode <= 82) ||
        (weatherCode >= 95 && weatherCode <= 99)) {
      return WeatherEffect.rain;
    }
    return WeatherEffect.none;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    generateParticles();
  }

  void generateParticles() {
    final Random random = Random();
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    _particles = List.generate(100, (_) {
      double speed = switch (effect) {
        WeatherEffect.snow => 1 + random.nextDouble() * 1.5,
        WeatherEffect.hail => 5 + random.nextDouble() * 2,
        WeatherEffect.rain => 3 + random.nextDouble() * 2,
        _ => 0,
      };
      double size = switch (effect) {
        WeatherEffect.snow => 2 + random.nextDouble() * 3,
        WeatherEffect.hail => 3 + random.nextDouble() * 3,
        WeatherEffect.rain => 1.5,
        _ => 0,
      };

      return Particle(
        position: Offset(
          random.nextDouble() * screenWidth,
          random.nextDouble() * screenHeight,
        ),
        speed: speed,
        size: size,
        effect: effect,
      );
    });
  }

  void updatePartcles() {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;
    for (var p in _particles) {
      p.position = Offset(p.position.dx, p.position.dy + p.speed);
      if (p.position.dy > screenHeight) {
        p.position = Offset(Random().nextDouble() * screenWidth, -10);
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (effect == WeatherEffect.none) return const SizedBox.shrink();

    return CustomPaint(
      size: Size.infinite,
      painter: WeatherSkyPainter(_particles),
    );
  }
}

class WeatherSkyPainter extends CustomPainter {
  final List<Particle> particles;
  WeatherSkyPainter(this.particles);

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint();
    for (var p in particles) {
      switch (p.effect) {
        case WeatherEffect.rain:
          paint.color = const Color.fromARGB(108, 153, 165, 180);
          canvas.drawLine(
            p.position,
            p.position.translate(0, p.size * 20),
            paint..strokeWidth = 1.5,
          );
          break;
        case WeatherEffect.snow:
          paint.color = const Color.fromARGB(255, 255, 255, 255);
          canvas.drawCircle(p.position, p.size - 2, paint);
          break;
        case WeatherEffect.hail:
          paint.color = const Color.fromARGB(255, 158, 158, 158);
          canvas.drawCircle(p.position, p.size - 3, paint);
          break;
        case WeatherEffect.none:
          break;
      }
    }
  }

  @override
  bool shouldRepaint(WeatherSkyPainter oldDelegate) => true;
}
