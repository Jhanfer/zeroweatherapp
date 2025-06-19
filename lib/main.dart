// ignore_for_file: library_private_types_in_public_api, prefer_typing_uninitialized_variables

import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:google_fonts/google_fonts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'update_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    return ChangeNotifierProvider(
      create: (context) => WeatherAPIState(),
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
  }
}

class WeatherAPIState with ChangeNotifier {
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

  final _cloudDescriptionPoints = {
    0: {"despejado": Icons.wb_sunny},
    15: {"mayormente despejado": Icons.wb_sunny},
    40: {"parcialmente nublado": Icons.wb_cloudy},
    65: {"mayormente nublado": Icons.cloud},
    85: {"muy nublado": Icons.cloud_queue},
    100: {"completamente nublado": Icons.cloud},
  };
  var cloudDescription = {};

  var temp = "";
  var maxTemp = "";
  var minTemp = "";
  var globalMap = {};
  var siteName = "";
  double? latitude = 0.0;
  double? longitude = 0.0;
  Position? position;

  var time = "";
  double? humidity;
  var aparentTemp = "";
  var wind = "";
  var rain = "";
  var pressure = "";
  var precipitation = "";
  var cloudCover = 0.0;

  var tempByHours = <double>[];
  var hours = <int>[];
  var dates = <DateTime>[];

  var appPermission = true;
  Timer? _timer;

  void startWeatherTimmer() async {
    _timer = Timer.periodic(Duration(seconds: 3), (timmer) async {
      await getWeather();
      await getTempByHour();
    });
    debugPrint("$_timer");
  }

  void startLocationTimmer() async {
    _timer = Timer.periodic(Duration(minutes: 2), (timmer) async {
      await getPrecisePosition();
    });
    debugPrint("$_timer");
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

  Future<void> updateSiteName(Position position) async {
    String safeSiteName = "Ubicación desconocida.";
    try {
      if (latitude != 0.0 && longitude != 0.0) {
        List<Placemark> placemarks = await placemarkFromCoordinates(
          latitude!,
          longitude!,
        );
        if (placemarks.isNotEmpty) {
          safeSiteName =
              placemarks.first.locality ??
              placemarks.first.subLocality ??
              "Ubicación desconocida.";
        }
      }
      globalMap = {
        "position": position,
        "latitude": latitude,
        "longitude": longitude,
        "safeSiteName": safeSiteName,
      };
    } catch (e) {
      debugPrint("Error al obtener el clima: $e");
    }
  }

  Future<void> getPrecisePosition() async {
    Position? position = await Geolocator.getLastKnownPosition();
    final prefs = await SharedPreferences.getInstance();
    debugPrint("GetPrecisePosition Iniciada.");
    try {
      position ??= await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      );

      if (position.latitude == 0.0 && position.longitude == 0.0) {
        latitude = prefs.getDouble('cached_latitude');
        longitude = prefs.getDouble('cached_longitude');
      } else {
        latitude = position.latitude;
        longitude = position.longitude;
        await prefs.setDouble('cached_latitude', position.latitude);
        await prefs.setDouble('cached_longitude', position.longitude);
      }
    } catch (e) {
      debugPrint("Error al obtener la ubicación: $e");
      latitude = 0.0;
      longitude = 0.0;
    }
    if (position != null) {
      await updateSiteName(position);
    }
    notifyListeners();
  }

  Future<void> getPosition() async {
    try {
      Position? position = await Geolocator.getLastKnownPosition();
      final prefs = await SharedPreferences.getInstance();
      debugPrint("GetPosition Iniciada.");
      position ??= await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
      );

      if (position.latitude == 0.0 && position.longitude == 0.0) {
        latitude = prefs.getDouble('cached_latitude');
        longitude = prefs.getDouble('cached_longitude');
      } else {
        latitude = position.latitude;
        longitude = position.longitude;
        await prefs.setDouble('cached_latitude', position.latitude);
        await prefs.setDouble('cached_longitude', position.longitude);
      }

      await updateSiteName(position);
    } catch (e) {
      debugPrint("Error al obtener la ubicación: $e");
      latitude = 0.0;
      longitude = 0.0;
    }

    notifyListeners();
  }

  Future<void> getTemp() async {
    var surl = Uri.parse(
      "https://api.open-meteo.com/v1/forecast?latitude=${globalMap["latitude"]}&longitude=${globalMap["longitude"]}&current=temperature_2m,apparent_temperature",
    );

    var dailyWeatherUrl = Uri.parse(
      "https://api.open-meteo.com/v1/forecast?latitude=${globalMap["latitude"]}&longitude=${globalMap["longitude"]}&daily=temperature_2m_max,temperature_2m_min",
    );

    try {
      final tempResponse = await http.get(surl);
      final dailyWeatherResponse = await http.get(dailyWeatherUrl);

      debugPrint(tempResponse.statusCode.toString());

      if (dailyWeatherResponse.statusCode == 200) {
        final dailyJsonData = jsonDecode(dailyWeatherResponse.body);
        maxTemp = dailyJsonData["daily"]["temperature_2m_max"][0]
            .toString()
            .split(".")[0];
        minTemp = dailyJsonData["daily"]["temperature_2m_min"][0]
            .toString()
            .split(".")[0];
      } else {
        if (dailyWeatherResponse.statusCode == 429) {
          emitEvent({"error": "Problema al verificar la conexión."});
        }
      }

      if (tempResponse.statusCode == 200) {
        final temoJsonData = jsonDecode(tempResponse.body);
        temp = temoJsonData["current"]["temperature_2m"].toString();
        aparentTemp = temoJsonData["current"]["apparent_temperature"]
            .toString();
        siteName = globalMap["safeSiteName"];
      }
    } catch (e) {
      debugPrint("Error: $e");
    }
    notifyListeners();
  }

  Future<void> getWeather() async {
    final url = Uri.parse(
      "https://api.open-meteo.com/v1/forecast?latitude=${globalMap["latitude"]}&longitude=${globalMap["longitude"]}&current=relative_humidity_2m,is_day,rain,precipitation,showers,snowfall,wind_speed_10m,wind_direction_10m,wind_gusts_10m,pressure_msl,surface_pressure,cloud_cover,weather_code",
    );

    try {
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        final currentTime = data["current"]["time"];
        final currentHumidity = data["current"]["relative_humidity_2m"];
        final currentRain = data["current"]["rain"];
        final currentPrecipitation = data["current"]["precipitation"];
        // ignore: unused_local_variable
        // final currentShowers = data["current"]["showers"];
        // ignore: unused_local_variable
        // final currentSnowfall = data["current"]["snowfall"];
        final currentWindSpeed = data["current"]["wind_speed_10m"];
        // ignore: unused_local_variable
        // final currentWindDirection = data["current"]["wind_direction_10m"];
        // ignore: unused_local_variable
        // final currentWindGusts = data["current"]["wind_gusts_10m"];
        final currentPressure = data["current"]["pressure_msl"];
        // ignore: unused_local_variable
        // final currentSurfacePressure = data["current"]["surface_pressure"];
        // ignore: unused_local_variable
        cloudCover = data["current"]["cloud_cover"] / 100 * 100;
        // ignore: unused_local_variable
        for (var point in _cloudDescriptionPoints.entries) {
          if (point.key <= cloudCover) {
            cloudDescription = point.value;
          }
        }
        // ignore: unused_local_variable
        // final currentWeatherCode = data["current"]["weather_code"];

        wind = currentWindSpeed.toString();
        rain = currentRain.toString();
        pressure = currentPressure.toString();
        precipitation = currentPrecipitation.toString();
        humidity = currentHumidity * 100 / 100;
        time = currentTime.toString();

        notifyListeners();
      }
    } catch (e) {
      debugPrint("Error: $e");
    }
  }

  Future<void> getTempByHour() async {
    http.Response? response;

    final url = Uri.parse(
      "https://api.open-meteo.com/v1/forecast?latitude=${globalMap["latitude"]}&longitude=${globalMap["longitude"]}&hourly=temperature_2m",
    );

    try {
      response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final hourlyTemp = data["hourly"]["temperature_2m"];
        final hourlyTime = data["hourly"]["time"];

        var now = DateTime.now().toLocal();
        final limit = now.add(Duration(hours: 24));

        for (var i in hourlyTime) {
          var parsed = DateTime.parse(i).toLocal();
          if (parsed.isAfter(now) && parsed.isBefore(limit)) {
            var test = parsed.hour;
            if (!hours.contains(test)) {
              hours.add(test);
              dates.add(parsed);
            }
          }
        }
        var hourLenght = hours.length;
        var parsedTemp = hourlyTemp.sublist(0, hourLenght);

        tempByHours = List<double>.from(parsedTemp);
      }
    } catch (e) {
      debugPrint("Error: $e");
    }
    notifyListeners();
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

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final weather = context.read<WeatherAPIState>();

      weather.checkPermissions().then((_) async {
        await weather.getPosition().then((_) {
          weather.checkInternet();
          weather.getTemp();
          weather.getWeather();
          weather.getTempByHour();
          weather.startWeatherTimmer();
          weather.startLocationTimmer();
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
              title: Text('Nueva versión disponible'),
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
                    update.downloadAndInstallApkHTTP();
                  },
                  child: Text("Actualizar"),
                ),
              ],
            ),
          );
        }
      });

      weather.eventStream.listen((event) {
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
    var weatherState = context.watch<WeatherAPIState>();
    var separatedTemp = weatherState.temp.split(".");

    var mainColor = Color.fromARGB(255, 10, 91, 119);
    var backgroundColor = Color.fromARGB(255, 40, 159, 208);
    var titleTextColor = Color.fromARGB(255, 244, 240, 88);
    var secondaryColor = Color.fromARGB(255, 2, 1, 34);

    var tempByHours = weatherState.tempByHours;
    var hours = weatherState.hours;
    var dates = weatherState.dates;

    return Scaffold(
      backgroundColor: backgroundColor,
      body: Stack(
        children: [
          Positioned.fill(child: MovingCloudsBackground()),
          weatherState.temp.isEmpty
              ? StartPage(mainColor: mainColor, secondaryColor: secondaryColor)
              : RefreshIndicator(
                  color: titleTextColor,
                  backgroundColor: mainColor,
                  displacement: 50.0,
                  edgeOffset: 0.0,
                  onRefresh: () async {
                    await weatherState.getPrecisePosition().then((_) {
                      weatherState.checkInternet();
                      weatherState.getTemp();
                      weatherState.getWeather();
                      weatherState.getTempByHour();
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
                                    weatherState: weatherState,
                                    mainColor: mainColor,
                                    separatedTemp: separatedTemp,
                                    secondaryColor: secondaryColor,
                                    hours: hours,
                                    tempByHours: tempByHours,
                                    titleTextColor: titleTextColor,
                                    dates: dates,
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
  });

  final WeatherAPIState weatherState;
  final Color mainColor;
  final Color secondaryColor;
  final List<String> separatedTemp;
  final Color titleTextColor;

  final List<double> tempByHours;
  final List<int> hours;
  final List<DateTime> dates;

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
                    key: ValueKey(separatedTemp[1]),
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      separatedTemp[1],
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
          "↑${weatherState.maxTemp}°/↓${weatherState.minTemp}°",
          style: GoogleFonts.kanit(
            fontSize: 27,
            color: mainColor,
            fontWeight: FontWeight.w300,
          ),
        ),
        Text(
          "Sensación térmica: ${weatherState.aparentTemp} °C",
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
                              "Cielo ${weatherState.cloudDescription.keys.first}",
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
                        height: 200,
                        child: LineChart(
                          LineChartData(
                            minX: -0.2,
                            maxX: spots.length - 0.9,
                            minY: (tempByHours.first) - 10,
                            maxY: (tempByHours.first) + 40,
                            gridData: FlGridData(show: false),
                            borderData: FlBorderData(show: false),
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
                                                .spotIndex]; // tu lista de horas
                                        final temp = barSpot.y.toStringAsFixed(
                                          1,
                                        ); // temperatura
                                        return LineTooltipItem(
                                          "$hour H\n$temp°C",
                                          const TextStyle(color: Colors.white),
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
                                  padding: EdgeInsets.all(12),
                                ),
                                sideTitles: SideTitles(
                                  reservedSize: 50,
                                  showTitles: false,
                                ),
                              ),
                              bottomTitles: const AxisTitles(
                                axisNameWidget: Padding(
                                  padding: EdgeInsets.all(12),
                                ),
                                sideTitles: SideTitles(
                                  reservedSize: 40,
                                  showTitles: false,
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
                              rightTitles: const AxisTitles(
                                axisNameWidget: Padding(
                                  padding: EdgeInsets.all(12),
                                ),
                                sideTitles: SideTitles(
                                  reservedSize: 40,
                                  showTitles: false,
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
    var weatherState = context.watch<WeatherAPIState>();
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

// ignore: must_be_immutable
class Cards extends StatelessWidget {
  Cards({super.key, required this.weatherState});

  final cardPadding = EdgeInsets.all(15);
  final WeatherAPIState weatherState;
  double fontCardSize = 18.0;

  var mainCardColor = Color.fromARGB(150, 10, 91, 119);
  var secondaryCardColor = Color.fromARGB(255, 67, 237, 253);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(1),
      child: GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        padding: EdgeInsets.all(30),
        shrinkWrap: true,
        physics: NeverScrollableScrollPhysics(),
        childAspectRatio: (1 / 0.8),
        children: [
          Card(
            color: mainCardColor,
            child: Padding(
              padding: cardPadding,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "Humedad: ${weatherState.humidity} %",
                    style: TextStyle(
                      fontSize: fontCardSize,
                      color: secondaryCardColor,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  SizedBox(
                    height: 10,
                    child: LinearProgressIndicator(
                      value: (weatherState.humidity ?? 1) / 100,
                      color: secondaryCardColor,
                      backgroundColor: mainCardColor,
                    ),
                  ),
                ],
              ),
            ),
          ),

          Card(
            color: mainCardColor,
            child: Padding(
              padding: cardPadding,
              child: Text(
                "Viento: ${weatherState.wind} km/h",
                style: TextStyle(
                  fontSize: fontCardSize,
                  color: secondaryCardColor,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ),
          ),
          Card(
            color: mainCardColor,
            child: Padding(
              padding: cardPadding,
              child: Text(
                "Presión: ${weatherState.pressure} hPa",
                style: TextStyle(
                  fontSize: fontCardSize,
                  color: secondaryCardColor,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ),
          ),
          Card(
            color: mainCardColor,
            child: Padding(
              padding: cardPadding,
              child: Text(
                "Precipitación: ${weatherState.precipitation} mm",
                style: TextStyle(
                  fontSize: fontCardSize,
                  color: secondaryCardColor,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ),
          ),
          Card(
            color: mainCardColor,
            child: Padding(
              padding: cardPadding,
              child: Text(
                "Lluvia: ${weatherState.rain} mm",
                style: TextStyle(
                  fontSize: fontCardSize,
                  color: secondaryCardColor,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ),
          ),
          SizedBox(width: 1000, height: 1, child: Card(color: mainCardColor)),
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
