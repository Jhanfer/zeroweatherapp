import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
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
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
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
  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initAsyncStuff();
    });
  }

  Future<void> _initAsyncStuff() async {
    final checkers = context.read<Checkers>();
    final newWeatherService = context.read<WeatherService>();
    checkers.checkPermissions().then((_) {
      checkers.checkInternet();
      newWeatherService.getPosition().then((_) {
        newWeatherService.loadStation().then((_) {
          newWeatherService.findNerbyStation();
          newWeatherService.getForecast().then((_) {
            newWeatherService.fetchMetarData();
            newWeatherService.getICA();
          });
        });
      });
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
                      ? "Descargando... ${eventProgress}%"
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

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    var newWeatherApi = context.watch<WeatherService>();
    var temp = newWeatherApi.metarCacheData!["temperature"].toString();
    var separatedTemp = temp.split(".");

    var mainColor = Color.fromARGB(255, 10, 91, 119);
    var backgroundColor = Color.fromARGB(255, 40, 159, 208);
    var titleTextColor = Color.fromARGB(255, 244, 240, 88);
    var secondaryColor = Color.fromARGB(255, 2, 1, 34);

    var tempByHours = newWeatherApi.forecastCachedData!["tempByHours"];
    var hours = newWeatherApi.forecastCachedData!["tempHours"];
    var dates = newWeatherApi.forecastCachedData!["dates"];
    var precipitation =
        newWeatherApi.forecastCachedData!["precipitationByHours"];

    return Scaffold(
      backgroundColor: backgroundColor,
      body: Stack(
        children: [
          Positioned.fill(child: MovingCloudsBackground()),
          newWeatherApi.metarCacheData!.isEmpty
              ? StartPage(mainColor: mainColor, secondaryColor: secondaryColor)
              : RefreshIndicator(
                  color: titleTextColor,
                  backgroundColor: mainColor,
                  displacement: 20.0,
                  edgeOffset: -10,
                  onRefresh: () async {
                    await newWeatherApi.getPrecisePosition().then((_) {
                      newWeatherApi.findNerbyStation();
                      newWeatherApi.getForecast();
                      newWeatherApi.fetchMetarData();
                      newWeatherApi.getICA();
                    });
                  },
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: MediaQuery.of(context).size.height,
                          ),
                          child: Align(
                            alignment: Alignment.center,
                            child: Container(
                              padding: EdgeInsets.only(top: 90),
                              child: Column(
                                mainAxisSize: MainAxisSize.max,
                                // La linea de "weatherState.temp.isEmpty ? const CircularProgressIndicator(): Row" es como si hicieramos un "widget = CircularProgressIndicator() if temp == "" else Column(...)" en python. es un if de una sola linea.
                                children: [
                                  IndexPage(
                                    weatherState: newWeatherApi,
                                    mainColor: mainColor,
                                    separatedTemp: separatedTemp,
                                    secondaryColor: secondaryColor,
                                    hours: (hours as List<dynamic>)
                                        .map((e) => e as int)
                                        .toList(),
                                    tempByHours: (tempByHours as List<dynamic>)
                                        .map((e) => e as double)
                                        .toList(),
                                    titleTextColor: titleTextColor,
                                    dates: (dates as List<dynamic>)
                                        .map((e) => DateTime.parse(e))
                                        .toList(),
                                    precipitation:
                                        (precipitation as List<dynamic>)
                                            .map((e) => e as double)
                                            .toList(),
                                  ),
                                ],
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
    );
  }
}

class IndexPage extends StatelessWidget {
  const IndexPage({
    super.key,
    required this.weatherState,
    required this.mainColor,
    required this.separatedTemp,
    required this.secondaryColor,
    required this.tempByHours,
    required this.hours,
    required this.titleTextColor,
    required this.dates,
    required this.precipitation,
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
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
                    ],
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
            height: 70,
            width: 340,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Text(
                    "ICA: ${weatherState.icaCache!["icaFinal"]}",
                    style: TextStyle(fontSize: 20, color: Colors.white),
                  ),
                  SizedBox(
                    height: 10,
                    width: 200,
                    child: LinearProgressIndicator(
                      borderRadius: BorderRadius.all(Radius.circular(600)),
                      backgroundColor: mainColor,
                      value:
                          ((weatherState.icaCache!["icaFinal"] * 100 / 100) ??
                              0) /
                          100,
                      color: _getColor(
                        ((weatherState.icaCache!["icaFinal"] * 100 / 100) ??
                                0) /
                            100,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Cards(weatherState: weatherState),
      ],
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
                elevation: 100,
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

// ignore: must_be_immutable
class Cards extends StatelessWidget {
  Cards({super.key, required this.weatherState});

  final cardPadding = EdgeInsets.all(15);
  final WeatherService weatherState;
  double fontCardSize = 18.0;

  var mainCardColor = Color.fromARGB(150, 10, 91, 119);
  var secondaryCardColor = Color.fromARGB(255, 67, 237, 253);
  var titleTextColor = Color.fromARGB(255, 244, 240, 88);

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
            elevation: 100,
            color: mainCardColor,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
                      Icon(Icons.sunny, color: Colors.white, size: 15),
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
            elevation: 100,
            color: mainCardColor,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
                      Icon(WeatherIcons.windy, color: Colors.white, size: 15),
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
                          angle: weatherState.metarCacheData!["widDirection"],
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
            elevation: 100,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Row(
                    children: [
                      Text(
                        "Presión ",
                        style: GoogleFonts.kanit(
                          fontSize: 13,
                          color: Colors.white,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      Icon(
                        WeatherIcons.barometer,
                        color: Colors.white,
                        size: 15,
                      ),
                    ],
                  ),
                  Text(
                    _getPressureAlertMessage(
                      double.parse(weatherState.metarCacheData!["pressure"]),
                    ).values.first,
                    style: GoogleFonts.kanit(fontSize: 13, color: Colors.white),
                  ),
                  Padding(
                    padding: EdgeInsetsGeometry.only(top: 10),
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
            elevation: 100,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
                      Icon(
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
            elevation: 100,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
                      Icon(Icons.dew_point, color: Colors.white, size: 15),
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
            elevation: 100,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
                      Icon(
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
  const MovingCloudsBackground({super.key});

  @override
  _MovingCloudsBackgroundState createState() => _MovingCloudsBackgroundState();
}

class _MovingCloudsBackgroundState extends State<MovingCloudsBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

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
            cloud1X: 0.2 + 0.1 * sin(2 * pi * _controller.value),
            cloud2X: 0.41 + 0.11 * sin(5 * pi * _controller.value),
            cloud3X: 0.21 + 0.33 * sin(5 * pi * _controller.value),
          ),
          child: SizedBox.expand(),
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
  });

  final double cloud1X;
  final double cloud2X;
  final double cloud3X;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 100);

    paint.color = Color.fromARGB(255, 201, 255, 5);
    canvas.drawCircle(
      Offset(size.width * cloud1X, size.height * 0.2),
      100,
      paint,
    );

    paint.color = Color.fromARGB(206, 218, 245, 255);
    canvas.drawCircle(
      Offset(size.width * cloud2X, size.height * 0.3),
      150,
      paint,
    );

    paint.color = Color.fromARGB(146, 218, 245, 255);
    canvas.drawCircle(
      Offset(size.width * cloud3X + 150, size.height * 0.5),
      150,
      paint,
    );

    paint.color = Color.fromARGB(132, 230, 248, 26);
    canvas.drawCircle(
      Offset(size.width * cloud1X * 2, size.height * 0.9),
      200,
      paint,
    );

    paint.color = Color.fromARGB(146, 60, 255, 0);
    paint.strokeWidth = 100;
    canvas.drawLine(
      Offset(size.width - 600, size.height - 50),
      Offset(size.width, size.height - 50),
      paint,
    );
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}
