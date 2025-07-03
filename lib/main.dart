import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'update_handler.dart';
import 'metar_weather_api.dart';
import 'package:fl_chart/fl_chart.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await FlutterDownloader.initialize(debug: true);
  FlutterDownloader.registerCallback(downloadCallback);

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

    update.eventStream.listen((event) {
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
                  update.downloadAndInstallApk();
                },
                child: Text("Actualizar"),
              ),
            ],
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
    debugPrint("$ica");
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

  String _getuvmessage(double uvIndex) {
    if (uvIndex >= 1.1) {
      return "Extremo!";
    } else if (uvIndex >= 0.8) {
      return "Demasiado alto";
    } else if (uvIndex >= 0.6) {
      return "Muy alto";
    } else if (uvIndex >= 0.3) {
      return "Alto";
    } else if (uvIndex >= 0) {
      return "Bajo";
    } else {
      return "No disponible";
    }
  }

  String _getDewPointClassification(double dewPoint, double temperature) {
    if (temperature < 16.0 && dewPoint < 10.0) {
      return "Frío y seco";
    } else if (temperature < 24.0 && dewPoint < 16.0) {
      return "Seco y cómodo";
    } else if (temperature < 28.0 && dewPoint >= 16.0 && dewPoint < 20.0) {
      return "Agradable";
    } else if (temperature < 28.0 && dewPoint >= 20.0) {
      return "Húmedo, pero templado";
    } else if (temperature >= 28.0 && dewPoint < 16.0) {
      return "Calor seco";
    } else if (temperature >= 28.0 && dewPoint >= 16.0 && dewPoint < 20.0) {
      return "Cálido con algo de humedad";
    } else if (temperature >= 28.0 && dewPoint >= 20.0 && dewPoint < 24.0) {
      return "Incomodidad moderada";
    } else if (temperature >= 30.0 && dewPoint >= 24.0) {
      return "Sofocante";
    } else {
      return "Sensación variable";
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
        padding: EdgeInsets.all(30),
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
                  Text(
                    "Índice UV: ${weatherState.forecastCachedData!["dailyUVIndexMax"][0]}",
                    style: GoogleFonts.kanit(
                      fontSize: fontCardSize,
                      color: Colors.white,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsetsGeometry.only(top: 50),
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
                          ),
                          style: GoogleFonts.kanit(
                            fontSize: 18,
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
                  Text(
                    "Viento: ${weatherState.metarCacheData!["windSpeed"]} km/h",
                    style: GoogleFonts.kanit(
                      fontSize: fontCardSize,
                      color: Colors.white,
                      fontWeight: FontWeight.w400,
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
                  Text(
                    "Presión: ${weatherState.metarCacheData!["pressure"]} hPa",
                    style: GoogleFonts.kanit(
                      fontSize: fontCardSize,
                      color: Colors.white,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsetsGeometry.only(top: 30),
                    child: SizedBox(
                      height: 10,
                      child: LinearProgressIndicator(
                        borderRadius: BorderRadius.all(Radius.circular(600)),
                        value:
                            (double.parse(
                              weatherState.metarCacheData!["pressure"],
                            )) /
                            2000,
                        color: secondaryCardColor,
                        backgroundColor: mainCardColor,
                      ),
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
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    "Precipitación: ${weatherState.forecastCachedData!["precipitationByHours"][0]} mm",
                    style: GoogleFonts.kanit(
                      fontSize: fontCardSize,
                      color: Colors.white,
                      fontWeight: FontWeight.w400,
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
                  Text(
                    "Punto de rocío:",
                    style: GoogleFonts.kanit(
                      fontSize: fontCardSize,
                      color: Colors.white,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  Text(
                    _getDewPointClassification(
                      weatherState.metarCacheData!["dewPoint"],
                      weatherState.metarCacheData!["temperature"],
                    ),
                    style: GoogleFonts.kanit(
                      fontSize: fontCardSize - 5,
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
                  Text(
                    "Humedad: ",
                    style: GoogleFonts.kanit(
                      fontSize: fontCardSize,
                      color: Colors.white,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  Padding(
                    padding: EdgeInsetsGeometry.only(top: 50),
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
