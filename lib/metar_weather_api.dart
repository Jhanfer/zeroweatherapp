import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import 'package:intl/intl.dart';
import 'package:weather_icons/weather_icons.dart';
import 'package:retry/retry.dart';
import 'package:location/location.dart' as loc;

class Station {
  final String code;
  final double latitude;
  final double longitude;
  final String name;
  final String continent;

  Station({
    required this.code,
    required this.latitude,
    required this.longitude,
    required this.name,
    required this.continent,
  });
}

class WeatherService with ChangeNotifier {
  List<Station> _stations = [];
  Station? _currentStation;
  List<Station> _nearbyStations = [];
  final Map<String, String> isoCountryToContinent = {
    // Norteamérica
    "US": "NA",
    "MX": "NA",
    "CA": "NA",
    "GT": "NA",
    "CU": "NA",
    "CR": "NA",

    // Sudamérica
    "BR": "SA",
    "AR": "SA",
    "CL": "SA",
    "CO": "SA",
    "PE": "SA",
    "UY": "SA",

    // Europa
    "ES": "EU",
    "FR": "EU",
    "DE": "EU",
    "IT": "EU",
    "NL": "EU",
    "PT": "EU",
    "RU": "EU", // Rusia principalmente en Europa
  };

  final _cloudDescriptionPoints = {
    0: {"despejado": WeatherIcons.day_sunny},
    15: {"mayormente despejado": WeatherIcons.day_cloudy_high},
    40: {"parcialmente nublado": WeatherIcons.day_cloudy},
    65: {"mayormente nublado": WeatherIcons.cloudy_gusts},
    85: {"muy nublado": WeatherIcons.cloudy},
    100: {"completamente nublado": WeatherIcons.cloudy_windy},
  };
  var cloudDescription = {};
  var appPermission = true;
  Map<String, dynamic>? metarCacheData = {};
  Map<String, dynamic>? forecastCachedData = {};
  Map<String, dynamic>? icaCache = {};

  var siteName = "";
  var country = "";
  var _currentPosition = {};
  var _lastPosition = {};

  Future<void> loadStation() async {
    try {
      //cargar los datos de las estaciones
      final csvString = await rootBundle.loadString("assets/stations.csv");

      //convertimos el csv a un listado de estaciones y le indicamos a "CsvToListConverter" que el separador es la coma ","
      List<List<dynamic>> rows = const CsvToListConverter(
        eol: "\n",
      ).convert(csvString);
      //creamos un listado de estaciones, donde cada estación que encaje en el "RegExp" (literalmente 4 letras mayusculas) se convierte a una estación parseando con map y las demás columnas usando "row[indicador]".
      _stations = rows
          .skip(1)
          .where(
            (row) => RegExp(
              r'^[A-Z]{4}$',
            ).hasMatch(row[0].toString().trim().toUpperCase()),
          )
          .map(
            (row) => Station(
              code: row[0].toString(),
              latitude: row[1] ?? 0.0,
              longitude: row[2] ?? 0.0,
              name: row[3].toString(),
              continent: row[4].toString(),
            ),
          )
          .toList();
    } catch (e) {
      debugPrint("$e");
    }
  }

  Future<void> updateSiteName() async {
    String safeSiteName = "Ubicación desconocida.";
    String currentCountry = "";

    Map? position =
        _currentPosition["latitude"] != null &&
            _currentPosition["longitude"] != null
        ? _currentPosition
        : (_lastPosition["latitude"] != null &&
                  _lastPosition["longitude"] != null
              ? _lastPosition
              : null);

    try {
      if (position != null) {
        List<Placemark> placemarks = await placemarkFromCoordinates(
          position["latitude"],
          position["longitude"],
        );

        if (placemarks.isNotEmpty) {
          safeSiteName =
              placemarks.first.locality ??
              placemarks.first.subLocality ??
              placemarks.first.street ??
              "Ubicación desconocida.";
          currentCountry = placemarks.first.isoCountryCode!;
        }
      }

      siteName = safeSiteName;

      country = currentCountry;
    } catch (e) {
      debugPrint("Error al obtener el nombre de localidad: $e");
    }
  }

  Future<void> getPrecisePosition() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "metar_last_position";
    Map<String, dynamic>? currentPosition;
    final String currentTimezone = await FlutterTimezone.getLocalTimezone();

    debugPrint("GetPrecisePosition Iniciada.");
    try {
      final cachedPositionJson = prefs.getString(cacheKey);
      if (cachedPositionJson != null) {
        final decodedPositionCache = jsonDecode(cachedPositionJson);
        final timeStamp = decodedPositionCache["timeStamp"] ?? 0;
        if (decodedPositionCache["timezone"] == null) {
          decodedPositionCache["timezone"] = currentTimezone;
        }

        if (DateTime.now().millisecondsSinceEpoch - timeStamp < 2 * 60 * 1000) {
          debugPrint("Usando posición mejorada cacheada.");
          currentPosition = decodedPositionCache;
        }
      } else {
        debugPrint("Caché de posición expirado, buscando nueva posición.");
      }

      if (currentPosition == null) {
        var newPosition = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.best,
        );
        currentPosition = {
          "latitude": newPosition.latitude,
          "longitude": newPosition.longitude,
          "timeStamp": DateTime.now().millisecondsSinceEpoch,
          "timezone": currentTimezone,
        };
        final success = await prefs.setString(
          cacheKey,
          json.encode(currentPosition),
        );
        debugPrint("¿Guardado posición en caché?: $success");
      }

      _currentPosition = currentPosition;
      await updateSiteName();

      debugPrint(
        "${_currentPosition["latitude"]}, ${_currentPosition["longitude"]}",
      );
    } catch (e) {
      debugPrint("Error al obtener la ubicación: $e");
    }

    notifyListeners();
  }

  Future<void> getPrecisePositionLocationMethod() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "metar_last_position";
    Map<String, dynamic>? currentPosition;
    final String currentTimezone = await FlutterTimezone.getLocalTimezone();
    final locService = loc.Location();

    debugPrint("getPrecisePositionLocationMethod Iniciada.");
    try {
      final cachedPositionJson = prefs.getString(cacheKey);
      if (cachedPositionJson != null) {
        final decodedPositionCache = jsonDecode(cachedPositionJson);
        final timeStamp = decodedPositionCache["timeStamp"] ?? 0;
        if (decodedPositionCache["timezone"] == null) {
          decodedPositionCache["timezone"] = currentTimezone;
        }

        if (DateTime.now().millisecondsSinceEpoch - timeStamp < 2 * 60 * 1000) {
          debugPrint("Usando posición mejorada cacheada.");
          currentPosition = decodedPositionCache;
        }
      } else {
        debugPrint("Caché de posición expirado, buscando nueva posición.");
      }

      if (currentPosition == null) {
        locService.changeSettings(accuracy: loc.LocationAccuracy.balanced);
        var newPosition = await locService.getLocation().timeout(
          Duration(seconds: 30),
        );
        currentPosition = {
          "latitude": newPosition.latitude,
          "longitude": newPosition.longitude,
          "timeStamp": DateTime.now().millisecondsSinceEpoch,
          "timezone": currentTimezone,
        };
        final success = await prefs.setString(
          cacheKey,
          json.encode(currentPosition),
        );
        debugPrint("¿Guardado posición en caché?: $success");
      }

      _currentPosition = currentPosition;
      await updateSiteName();

      debugPrint(
        "${_currentPosition["latitude"]}, ${_currentPosition["longitude"]}",
      );
    } catch (e) {
      debugPrint("Error al obtener la ubicación: $e");
    }

    notifyListeners();
  }

  Future<void> getPosition() async {
    debugPrint("New GetPosition Iniciada.");
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "metar_last_position";
    Map<String, dynamic>? freshPositionData;
    final String currentTimezone = await FlutterTimezone.getLocalTimezone();
    Position? newPosition;

    debugPrint("Zona horaria actual $currentTimezone");

    try {
      final cachedPositionJson = prefs.getString(cacheKey);
      if (cachedPositionJson != null) {
        final decodedPositionCache = jsonDecode(cachedPositionJson);
        final timeStamp = decodedPositionCache["timeStamp"] ?? 0;
        // Siempre asignamos la última posición cargada del caché a _lastKnownPosition
        if (decodedPositionCache["timezone"] == null) {
          decodedPositionCache["timezone"] = currentTimezone;
        }

        _lastPosition = decodedPositionCache;

        if (DateTime.now().millisecondsSinceEpoch - timeStamp <
            30 * 60 * 1000) {
          debugPrint("CachedPosition");
          freshPositionData = decodedPositionCache;
          _currentPosition = freshPositionData!;
        }
      } else {
        debugPrint("Caché de posición expirado, buscando nueva posición.");
      }
      try {
        if (freshPositionData == null || hasMovedSignificantly()) {
          newPosition = await Geolocator.getLastKnownPosition();
          if (newPosition != null) {
            newPosition = await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.low,
              timeLimit: Duration(seconds: 30),
            );
          }

          freshPositionData = {
            "latitude": newPosition?.latitude ?? 0.0,
            "longitude": newPosition?.longitude ?? 0.0,
            "timeStamp": DateTime.now().millisecondsSinceEpoch,
            "timezone": currentTimezone,
          };
          final success = await prefs.setString(
            cacheKey,
            json.encode(freshPositionData),
          );
          debugPrint("¿Guardado posición en caché?: $success");
        }
      } catch (e) {
        debugPrint("Ha ocurrido un error al obtener la ubicación: $e");
      }

      // Si se obtuvo una nueva posición, también actualizamos _lastKnownPosition
      _lastPosition = freshPositionData!;
    } catch (e) {
      debugPrint("Error al obtener la ubicación: $e");
    }
    if (freshPositionData != null) {
      _currentPosition = freshPositionData;

      var lat = _currentPosition["latitude"] ?? _lastPosition["latitude"];
      var long = _currentPosition["longitude"] ?? _lastPosition["longitude"];

      debugPrint("Usando currentPosition: $lat, $long");
    }
    await updateSiteName();
    notifyListeners();
  }

  //Encontrar la estación más cercana
  findNerbyStation() {
    debugPrint("Iniciando búsqueda de estación cercana.");
    if (_stations.isEmpty) {
      debugPrint("No hay estaciones disponibles.");
      _nearbyStations = [];
      notifyListeners();
      return;
    }
    // Ordenar estaciones por distancia
    List<Map<String, dynamic>> stationsWithDistance = _stations.map((station) {
      double distance = Geolocator.distanceBetween(
        _currentPosition["latitude"] ?? 0.0,
        _currentPosition["longitude"] ?? 0.0,
        station.latitude,
        station.longitude,
      );
      return {'station': station, 'distance': distance};
    }).toList();

    // Ordenar por distancia ascendente
    stationsWithDistance.sort((a, b) => a["distance"].compareTo(b["distance"]));

    // Tomar las 3 estaciones más cercanas (o menos si no hay suficientes)
    _nearbyStations = stationsWithDistance
        .take(3)
        .map<Station>((entry) => entry["station"] as Station)
        .toList();

    // Establecer la estación más cercana como _currentStation
    _currentStation = _nearbyStations.isNotEmpty ? _nearbyStations.first : null;
    debugPrint(
      "Estaciones cercanas encontradas: ${_nearbyStations.map((s) => s.code).join(', ')}",
    );
    notifyListeners();
  }

  bool hasMovedSignificantly() {
    // Extraer las latitudes y longitudes de los mapas
    final double currentLat = _currentPosition["latitude"] as double;
    final double currentLon = _currentPosition["longitude"] as double;
    final double lastLat = _lastPosition["latitude"] as double;
    final double lastLon = _lastPosition["longitude"] as double;

    // Calcular la distancia en metros usando geolocator
    final double distanceInMeters = Geolocator.distanceBetween(
      currentLat,
      currentLon,
      lastLat,
      lastLon,
    );
    // Convertir el umbral de kilómetros a metros para la comparación
    var thresholdKM = 0.5;
    final double thresholdMeters = thresholdKM * 1000;

    return distanceInMeters >= thresholdMeters;
  }

  //API para procesar datos METAR y combinar con NOAA
  Future<void> fetchMetarData() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "metar_$_currentStation";
    final cachedData = prefs.getString(cacheKey);
    http.Response? metarResponse;
    http.Response? meteoResponse;
    Map<String, dynamic>? dataToUse;

    //Verificar si hay datos en la memoria caché
    if (cachedData != null) {
      final data = jsonDecode(cachedData);
      final timeStamp = data["timeStamp"] ?? 0;

      if (DateTime.now().millisecondsSinceEpoch - timeStamp < 10 * 60 * 1000) {
        debugPrint("CachedData");
        //Si el tiempo de cache es menor a 30 minutos, usar datos de la memoria caché, de lo contrario, rescatar nueva info
        dataToUse = data;
      }
    }

    if (dataToUse == null || hasMovedSignificantly()) {
      // Descargar los datos METAR
      final client = http.Client();
      try {
        Future<http.Response> metarFuture;
        Future<http.Response> meteoFuture;

        if (country.isNotEmpty) {
          if (country.toLowerCase() == "es" ||
              country.toLowerCase() == "spain") {
            metarFuture = client.get(
              Uri.parse(
                "https://tgftp.nws.noaa.gov/data/observations/metar/stations/${_currentStation!.code}.TXT",
              ),
            );
          } else {
            metarFuture = client.get(
              Uri.parse(
                "https://aviationweather.gov/api/data/metar?ids=${_currentStation!.code}&format=raw",
              ),
              headers: {
                'User-Agent':
                    'TuApp/1.0 (zeroweather.app.api)', // Requerido para APIs de NWS
              },
            );
          }

          meteoFuture = client.get(
            Uri.parse(
              "https://api.open-meteo.com/v1/forecast?latitude=${_currentPosition["latitude"]}&longitude=${_currentPosition["longitude"]}&current=is_day,precipitation,showers,snowfall,wind_gusts_10m,pressure_msl,cloud_cover,weather_code&timezone=${_lastPosition["timezone"]}",
            ),
          );

          final results = await Future.wait([metarFuture, meteoFuture]);
          metarResponse = results[0];
          meteoResponse = results[1];

          if (metarResponse.statusCode != 200 ||
              metarResponse.body.isEmpty == true) {
            for (var station in _nearbyStations) {
              metarResponse = await client.get(
                Uri.parse(
                  "https://tgftp.nws.noaa.gov/data/observations/metar/stations/${station.code}.TXT",
                ),
              );
              if (metarResponse.statusCode == 200) {
                debugPrint("estación que funciona ${station.code}");
                _currentStation = station;
                break;
              }
            }
          }
        }
      } catch (e) {
        debugPrint("Ha ocurrido un error en la descarga de los datos METAR$e");
      } finally {
        client.close();
      }

      if (metarResponse?.statusCode == 200 &&
          meteoResponse?.statusCode == 200) {
        debugPrint("OnlineData");

        final lines = metarResponse?.body.split("\n");
        debugPrint("$lines");
        //Datos de api externa
        final externalData = jsonDecode(meteoResponse!.body);
        String? temp, dewPoint, pressure, condition;
        DateTime? dateTime;
        double? windKmh, widDirection;

        try {
          for (var line in lines!) {
            final parts = line.trim().split(" ");
            for (var part in parts) {
              if (part.length == 7 && part.endsWith("Z")) {
                int day = int.parse(part.substring(0, 2));
                int hour = int.parse(part.substring(2, 4));
                int minute = int.parse(part.substring(4, 6));
                final now = DateTime.now();
                dateTime = DateTime.parse(
                  "${now.year}-${now.month.toString().padLeft(2, "0")}-${day.toString().padLeft(2, "0")} ${hour.toString().padLeft(2, "0")}:${minute.toString().padLeft(2, "0")}:00",
                ).toUtc();
              }

              if (part.contains("/")) {
                final tempDewRegex = RegExp(r"^M?\d{2}/M?\d{2}$");
                // "^" y "$" aseguran que todos los digitos encajen. "M?\d{2}" significa que puede haber un "M" opcional seguido de 2 digitos. "/" una barra normal. "M?\d{2}" lo mismo que antes.
                if (tempDewRegex.hasMatch(part)) {
                  final tempDew = part.split("/");
                  //Temperatura
                  var initialTemp = tempDew[0].replaceFirst("M", "-");
                  var normalizedTemp =
                      (int.parse(initialTemp) * 0.4) +
                      (forecastCachedData!["tempByHours"][0] * 0.6);

                  temp = normalizedTemp.toString();

                  //Punto de rocío
                  dewPoint = tempDew[1].replaceFirst("M", "-");
                }
              }
              if (part.contains("KT")) {
                var windSpeed = part; //Viento

                var direction = RegExp(r'^(\d{3})').firstMatch(windSpeed);

                if (direction != null) {
                  widDirection = double.parse(direction.group(1)!);
                }

                final speedMatch = RegExp(
                  r'(\d{2,3})(?:G\d{2,3})?KT$',
                ).firstMatch(windSpeed);
                if (speedMatch != null) {
                  final speedKt = int.parse(speedMatch.group(1)!);
                  if (speedKt >= 0 && speedKt <= 100) {
                    // Validar rango razonable
                    final speedKmh = speedKt * 1.852;
                    windKmh = speedKmh; // Ej. 16.7 km/h
                  } else {
                    windKmh = 0.0; // Velocidad fuera de rango
                  }
                } else {
                  windKmh = 0.0; // No se pudo extraer velocidad
                }
              }
              if (part.startsWith("Q") ||
                  part.startsWith("A") && part.length == 5) {
                final pressureString = part.substring(1); //eliminar Q o A
                if (part.startsWith("Q")) {
                  pressure = pressureString;
                } else {
                  final intValue = int.tryParse(pressureString);
                  if (intValue != null) {
                    double pressureDouble = intValue / 100;
                    const double conversionFactor = 33.86388666667;
                    pressure = (pressureDouble * conversionFactor)
                        .toStringAsFixed(2);
                  }
                }
              }
              if (["CLR", "FEW", "SCT", "BKN", "OVC"].contains(part)) {
                condition = part; //Condición
              }
            }
          }
        } catch (e) {
          debugPrint(
            "Ha ocurrido un error al parsear el texto de la predicción: $e",
          );
        }

        if (temp != null && dewPoint != null) {
          double tempC = double.parse(temp);
          double dewPointC = double.parse(dewPoint);
          double? heatIndex;

          //Calcular humedad
          var vaporDewPressure =
              6.112 * exp((17.625 * dewPointC) / (dewPointC + 243.04));
          var vaporTempPressure =
              6.112 * exp((17.625 * tempC) / (tempC + 243.04));
          double humidity = 100 * (vaporDewPressure / vaporTempPressure);

          //Calcular sensación térmica
          if (tempC < 10.0 && windKmh != null && windKmh > 4.8) {
            final v = pow(windKmh, 0.16);
            heatIndex = 13.12 + 0.6215 * tempC - 11.37 * v + 0.3965 * tempC * v;
          } else if (tempC > 27.0 && humidity > 40) {
            // Convertir °C a °F
            final T = tempC * 9 / 5 + 32;
            final rh = humidity;
            // Fórmula NOAA para Heat Index en °F
            final hi =
                -42.379 +
                2.04901523 * T +
                10.14333127 * rh -
                0.22475541 * T * rh -
                6.83783e-3 * T * T -
                5.481717e-2 * rh * rh +
                1.22874e-3 * T * T * rh +
                8.5282e-4 * T * rh * rh -
                1.99e-6 * T * T * rh * rh;

            // Convertir HI de °F a °C
            heatIndex = (hi - 32) * 5 / 9;
          } else {
            heatIndex = tempC;
          }

          dataToUse = {
            "temperature": tempC,
            "dewPoint": dewPointC,
            "humidity": humidity.roundToDouble().clamp(0, 100),
            "windSpeed": windKmh,
            "widDirection": widDirection,
            "heatIndex": heatIndex.toStringAsFixed(2),
            "pressure": pressure ?? "NA",
            "condition": condition ?? "NA",
            "cloudCover":
                (externalData["current"]["cloud_cover"] / 100 * 100 as num)
                    .clamp(0, 100),
            "dateTime": dateTime.toString(),
            "currentPrecipitation": externalData["current"]["precipitation"],
            "currentShowers": externalData["current"]["showers"],
            "currentSnowfall": externalData["current"]["snowfall"],
            "currentWindGusts": externalData["current"]["wind_gusts_10m"],
            "currentSurfacePressure":
                externalData["current"]["surface_pressure"],
            "isDay": externalData["current"]["is_day"],
            "timeStamp": DateTime.now().millisecondsSinceEpoch,
            "weather_code": externalData["current"]["weather_code"],
            "METAR_ICAO": _currentStation!.code,
          };

          debugPrint(_currentStation!.name);

          //Guardar caché
          final success = await prefs.setString(
            cacheKey,
            json.encode(dataToUse),
          );
          debugPrint("¿Guardado el tiempo en caché?: $success");
        } else {
          throw Exception("No se pudo obtener la información del clima");
        }
      }
    }

    //Nubes fuera del try para mejor manejo
    if (dataToUse != null) {
      for (var point in _cloudDescriptionPoints.entries) {
        if (point.key <= dataToUse["cloudCover"]) {
          cloudDescription = point.value;
        }
      }
    }
    metarCacheData = dataToUse;
    notifyListeners();
  }

  Future<Map> getPositionBackground() async {
    debugPrint("Get position background");
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "metar_last_position";
    Map<String, dynamic>? freshPositionData;
    final String currentTimezone = await FlutterTimezone.getLocalTimezone();
    final locService = loc.Location();

    try {
      final cachedPositionJson = prefs.getString(cacheKey);
      if (cachedPositionJson != null) {
        final decodedPositionCache = jsonDecode(cachedPositionJson);
        final timeStamp = decodedPositionCache["timeStamp"] ?? 0;
        if (decodedPositionCache["timezone"] == null) {
          decodedPositionCache["timezone"] = currentTimezone;
        }
        if (DateTime.now().millisecondsSinceEpoch - timeStamp <
            10 * 60 * 1000) {
          freshPositionData = decodedPositionCache;
        }
      } else {
        debugPrint("Caché de posición expirado, buscando nueva posición.");
      }
      try {
        if (freshPositionData == null) {
          locService.changeSettings(accuracy: loc.LocationAccuracy.low);
          var newPosition = await locService.getLocation().timeout(
            Duration(seconds: 30),
          );

          freshPositionData = {
            "latitude": newPosition.latitude,
            "longitude": newPosition.longitude,
            "timeStamp": DateTime.now().millisecondsSinceEpoch,
            "timezone": currentTimezone,
          };
          final success = await prefs.setString(
            cacheKey,
            json.encode(freshPositionData),
          );
          debugPrint("¿Guardado posición en caché?: $success");
        }
      } catch (e) {
        debugPrint("Ha ocurrido un error al obtener la ubicación: $e");
      }
    } catch (e) {
      debugPrint("Error al obtener la ubicación: $e");
    }

    return freshPositionData ?? {};
  }

  Future<Map<String, dynamic>> fetchDataBackground() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "background_MetarData";
    final cachedData = prefs.getString(cacheKey);
    http.Response? forecastHourlyResponse;
    http.Response? meteoResponse;
    Map<String, dynamic>? dataToUse;

    //Verificar si hay datos en la memoria caché
    debugPrint("Empezando metar background");
    if (cachedData != null) {
      final data = jsonDecode(cachedData);
      final timeStamp = data["timeStamp"] ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - timeStamp < 10 * 60 * 1000) {
        dataToUse = data;
        debugPrint("Usando los datos en caché (Una hora).");
      }
    }

    final position = await getPositionBackground();
    final timezone = position["timezone"] ?? "auto";

    if (dataToUse == null) {
      try {
        meteoResponse = await retry(
          () => http.get(
            Uri.parse(
              "https://api.open-meteo.com/v1/forecast?latitude=${position["latitude"]}&longitude=${position["longitude"]}&current=cloud_cover&timezone=$timezone",
            ),
          ),
          maxAttempts: 3,
          delayFactor: Duration(seconds: 3),
        );

        forecastHourlyResponse = await retry(
          () => http.get(
            Uri.parse(
              "https://api.open-meteo.com/v1/forecast?latitude=${position["latitude"]}&longitude=${position["longitude"]}&hourly=temperature_2m,precipitation_probability,uv_index&timezone=$timezone",
            ),
          ),
          maxAttempts: 3,
          delayFactor: Duration(seconds: 3),
        );
      } catch (e) {
        debugPrint(
          "Ha ocurrido un error al sacar los datos en segundo plano $e",
        );
      }
      if (meteoResponse?.statusCode == 200 &&
          forecastHourlyResponse?.statusCode == 200) {
        //Datos de api externa
        final externalData = jsonDecode(meteoResponse!.body);
        final houtlyData = jsonDecode(forecastHourlyResponse!.body);

        final hourlyTemp = houtlyData["hourly"]["temperature_2m"];
        final hourlyTime = houtlyData["hourly"]["time"];
        final hourlyPrecipitationProbability =
            houtlyData["hourly"]["precipitation_probability"];

        double? temperatureIn8Hours;
        double? precipitationProbabilityIn8Hours;

        Duration smallestDifference = Duration(days: 999);

        var now = DateTime.now().toLocal();
        final limit = now.add(const Duration(hours: 8));

        for (int i = 0; i < hourlyTime.length; i++) {
          var parsed = DateTime.parse(hourlyTime[i]).toLocal();
          Duration difference = parsed.difference(limit).abs();
          if (parsed.isAfter(now) || parsed.isAtSameMomentAs(now)) {
            if (difference < smallestDifference) {
              smallestDifference = difference;
              temperatureIn8Hours = (hourlyTemp[i] as num).toDouble();
              precipitationProbabilityIn8Hours =
                  (hourlyPrecipitationProbability[i] as num).toDouble();
            }
          }
        }

        dataToUse = {
          "temperature": temperatureIn8Hours,
          "cloudCover": externalData["current"]["cloud_cover"] / 100 * 100,
          "precipitation": precipitationProbabilityIn8Hours,
          "dateTime": DateTime.now().toString(),
          "currentPrecipitation": externalData["current"]["precipitation"],
          "currentShowers": externalData["current"]["showers"],
          "currentSnowfall": externalData["current"]["snowfall"],
          "timeStamp": DateTime.now().millisecondsSinceEpoch,
        };

        //Guardar caché
        final success = await prefs.setString(cacheKey, json.encode(dataToUse));
        debugPrint("¿Guardado en caché segundo plano?: $success");
      }
    }
    return dataToUse ?? {};
  }

  Future<void> getForecast() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "meteo_forecast";
    final forecastCached = prefs.getString(cacheKey);
    http.Response? forecastHourlyResponse;
    http.Response? forecastDailyResponse;
    Map<String, dynamic>? dataToUse;

    if (forecastCached != null) {
      final data = jsonDecode(forecastCached);
      final timeStamp = data["timeStamp"] ?? 0;

      if (DateTime.now().millisecondsSinceEpoch - timeStamp < 10 * 60 * 1000) {
        //rectificador para nuevos datos
        if (data["dailyMaxTemps"] == null) {
          data["dailyMaxTemps"] = [0.0, 0.0];
        } else if (data["dailyMinTemps"] == null) {
          data["dailyMinTemps"] = [0.0, 0.0];
        } else if (data["dailyPrecipitationTotals"] == null) {
          data["dailyPrecipitationTotals"] = [0.0, 0.0];
        } else if (data["weekDays"] == null) {
          data["weekDays"] = ["none", "none"];
        }

        debugPrint("CachedForecastData");
        dataToUse = data;
      }
    }

    if (dataToUse == null || hasMovedSignificantly()) {
      final client = http.Client();
      try {
        Future<http.Response> forecastHourlyFuture;
        Future<http.Response> forecastDailyFuture;
        forecastHourlyFuture = client.get(
          Uri.parse(
            "https://api.open-meteo.com/v1/forecast?latitude=${_currentPosition["latitude"]}&longitude=${_currentPosition["longitude"]}&hourly=temperature_2m,precipitation_probability,uv_index&timezone=${_lastPosition["timezone"]}",
          ),
        );

        forecastDailyFuture = client.get(
          Uri.parse(
            "https://api.open-meteo.com/v1/forecast?latitude=${_currentPosition["latitude"]}&longitude=${_currentPosition["longitude"]}&daily=sunrise,sunset,sunshine_duration,daylight_duration&timezone=${_lastPosition["timezone"]}",
          ),
        );

        final results = await Future.wait([
          forecastHourlyFuture,
          forecastDailyFuture,
        ]);
        forecastHourlyResponse = results[0];
        forecastDailyResponse = results[1];
      } catch (e) {
        debugPrint("Se ha presentado un error: $e");
      }

      if (forecastHourlyResponse!.statusCode == 200 &&
          forecastDailyResponse!.statusCode == 200) {
        final houtlyData = jsonDecode(forecastHourlyResponse.body);
        final hourlyTemp = houtlyData["hourly"]["temperature_2m"];
        final hourlyTime = houtlyData["hourly"]["time"];
        final hourlyPrecipitationProbability =
            houtlyData["hourly"]["precipitation_probability"];
        final hourlyUVIndex = houtlyData["hourly"]["uv_index"];
        List<int> hours = [];
        List<String> dates = [];
        List<double> parsedTemp = [];
        List<double> parsedPrecipitation = [];
        List<double> dailyUVIndexMax = [];

        Map<String, List<double>> dailyTemps = {};
        Map<String, List<double>> dailyPrecipitation = {};

        var now = DateTime.now().toLocal();
        final limit = now.add(const Duration(hours: 24));
        final weekLimit = now.add(const Duration(days: 7));

        for (int i = 0; i < hourlyTime.length; i++) {
          var parsed = DateTime.parse(hourlyTime[i]).toLocal();
          if (parsed.isBefore(now) && parsed.isAfter(weekLimit)) continue;

          final dateKey =
              "${parsed.year}-${parsed.month.toString().padLeft(2, "0")}-${parsed.day.toString().padLeft(2, "0")}";

          dailyTemps.putIfAbsent(dateKey, () => []);
          dailyTemps[dateKey]!.add((hourlyTemp[i] as num).toDouble());

          dailyPrecipitation.putIfAbsent(dateKey, () => []);
          dailyPrecipitation[dateKey]!.add(
            (hourlyPrecipitationProbability[i] as num).toDouble(),
          );
        }

        List<double> dailyMaxTemps = [];
        List<double> dailyMinTemps = [];
        List<int> dailyPrecipitationTotals = [];
        List<String> weekDays = [];

        for (var entry in dailyTemps.entries) {
          final temps = entry.value;
          final precipitations = dailyPrecipitation[entry.key];
          dailyMaxTemps.add(
            temps.reduce(
              (currentMax, element) =>
                  element > currentMax ? element : currentMax,
            ),
          );
          dailyMinTemps.add(
            temps.reduce(
              (currentMin, element) =>
                  element < currentMin ? element : currentMin,
            ),
          );

          dailyPrecipitationTotals.add(
            (precipitations!.reduce((a, b) => a + b) / precipitations.length)
                .toInt(),
          );

          final date = DateTime.parse(entry.key);
          var dayName = DateFormat.EEEE("es").format(date);

          if (date.day == now.day) {
            dayName = "Hoy";
          }

          weekDays.add(dayName[0].toUpperCase() + dayName.substring(1));
        }

        for (int i = 0; i < hourlyTime.length; i++) {
          var parsed = DateTime.parse(hourlyTime[i]).toLocal();
          if (parsed.isAfter(now) &&
              parsed.isBefore(limit) &&
              !hours.contains(parsed.hour)) {
            hours.add(parsed.hour);
            dates.add(parsed.toIso8601String());

            parsedTemp.add(hourlyTemp[i].toDouble());
            parsedPrecipitation.add(
              hourlyPrecipitationProbability[i].toDouble(),
            );
            if (parsed.hour == now.hour) {
              dailyUVIndexMax.add(hourlyUVIndex[i].toDouble());
            }
          }
        }

        final dailyData = jsonDecode(forecastDailyResponse.body);
        final dailySunrise = dailyData["daily"]["sunrise"][0];
        final dailySunset = dailyData["daily"]["sunset"][0];
        final dailySunshineDuration = dailyData["daily"]["sunshine_duration"];
        final dailyDaylightDuration = dailyData["daily"]["daylight_duration"];

        var maxTemp = parsedTemp.reduce(
          (currentMax, element) => element > currentMax ? element : currentMax,
        );
        var minTemp = parsedTemp.reduce(
          (currentMin, element) => element < currentMin ? element : currentMin,
        );

        dataToUse = {
          "tempHours": hours,
          "precipitationByHours": parsedPrecipitation,
          "tempByHours": parsedTemp,
          "maxTemp": maxTemp,
          "minTemp": minTemp,
          "dates": dates,
          "dailySunrise": dailySunrise,
          "dailySunset": dailySunset,
          "dailySunshineDuration": dailySunshineDuration,
          "dailyDaylightDuration": dailyDaylightDuration,
          "dailyUVIndexMax": dailyUVIndexMax,
          "daysMaxTemps": dailyMaxTemps,
          "daysMinTemps": dailyMinTemps,
          "daysPrecipitationTotals": dailyPrecipitationTotals,
          "weekDays": weekDays,
          "timeStamp": DateTime.now().millisecondsSinceEpoch,
        };
      }
      //Guardar caché
      final success = await prefs.setString(cacheKey, json.encode(dataToUse));
      debugPrint("¿Guardado forecast en caché?: $success");
    }

    forecastCachedData = dataToUse;
    notifyListeners();
  }

  int? calcularICA(double concentracion, List breakpoints) {
    for (final bp in breakpoints) {
      if (concentracion >= bp.clo && concentracion <= bp.chi) {
        return ((bp.ihi - bp.ilo) /
                    (bp.chi - bp.clo) *
                    (concentracion - bp.clo) +
                bp.ilo)
            .round();
      }
    }
    return null; // fuera de rango
  }

  Future<void> getICA() async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = "ICA";
    final icaCachedData = prefs.getString(cacheKey);
    http.Response? icaResponse;
    Map<String, dynamic>? dataToUse;

    if (icaCachedData != null) {
      final data = jsonDecode(icaCachedData);
      final timeStamp = data["timeStamp"] ?? 0;

      if (DateTime.now().millisecondsSinceEpoch - timeStamp < 30 * 60 * 1000) {
        debugPrint("CachedICAData");
        dataToUse = data;
      }
    }

    final pm25Breakpoints = [
      Breakpoint(0.0, 12.0, 0, 50),
      Breakpoint(12.1, 35.4, 51, 100),
      Breakpoint(35.5, 55.4, 101, 150),
      Breakpoint(55.5, 150.4, 151, 200),
      Breakpoint(150.5, 250.4, 201, 300),
      Breakpoint(250.5, 350.4, 301, 400),
      Breakpoint(350.5, 500.4, 401, 500),
    ];

    final pm10Breakpoints = [
      Breakpoint(0.0, 54.0, 0, 50),
      Breakpoint(55.0, 154.0, 51, 100),
      Breakpoint(155.0, 254.0, 101, 150),
      Breakpoint(255.0, 354.0, 151, 200),
      Breakpoint(355.0, 424.0, 201, 300),
      Breakpoint(425.0, 504.0, 301, 400),
      Breakpoint(505.0, 604.0, 401, 500),
    ];

    final ozoneBreakpoints = [
      Breakpoint(0.0, 120.0, 0, 50),
      Breakpoint(121.0, 180.0, 51, 100),
      Breakpoint(181.0, 240.0, 101, 150),
      Breakpoint(241.0, 300.0, 151, 200),
      Breakpoint(301.0, 400.0, 201, 300),
      Breakpoint(401.0, 800.0, 301, 500),
    ];

    final nitrogenDioxideBreakpoints = [
      Breakpoint(0.0, 40.0, 0, 50),
      Breakpoint(41.0, 80.0, 51, 100),
      Breakpoint(81.0, 180.0, 101, 150),
      Breakpoint(181.0, 280.0, 151, 200),
      Breakpoint(281.0, 400.0, 201, 300),
      Breakpoint(401.0, 520.0, 301, 400),
      Breakpoint(521.0, 650.0, 401, 500),
    ];

    final sulphurDioxideBreakpoints = [
      Breakpoint(0.0, 20.0, 0, 50),
      Breakpoint(21.0, 80.0, 51, 100),
      Breakpoint(81.0, 250.0, 101, 150),
      Breakpoint(251.0, 350.0, 151, 200),
      Breakpoint(351.0, 500.0, 201, 300),
      Breakpoint(501.0, 750.0, 301, 400),
      Breakpoint(751.0, 1000.0, 401, 500),
    ];

    final carbonMonoxideBreakpoints = [
      // CO viene en µg/m³ y debe convertirse a mg/m³ (dividir entre 1000)
      Breakpoint(0.0, 4.4, 0, 50),
      Breakpoint(4.5, 9.4, 51, 100),
      Breakpoint(9.5, 12.4, 101, 150),
      Breakpoint(12.5, 15.4, 151, 200),
      Breakpoint(15.5, 30.4, 201, 300),
      Breakpoint(30.5, 40.4, 301, 400),
      Breakpoint(40.5, 50.4, 401, 500),
    ];

    if (dataToUse == null || hasMovedSignificantly()) {
      try {
        icaResponse = await http.get(
          Uri.parse(
            "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${_currentPosition["latitude"]}&longitude=${_currentPosition["longitude"]}&current=pm2_5,carbon_monoxide,sulphur_dioxide,ozone,nitrogen_dioxide,pm10",
          ),
        );

        if (icaResponse.statusCode == 200) {
          final data = jsonDecode(icaResponse.body);
          final pm25 = data["current"]["pm2_5"];
          final pm10 = data["current"]["pm10"];
          final carbonMonoxide = data["current"]["carbon_monoxide"];
          final sulphurDioxide = data["current"]["sulphur_dioxide"];
          final ozone = data["current"]["ozone"];
          final nitrogenDioxide = data["current"]["nitrogen_dioxide"];

          final icas = [
            calcularICA(pm25, pm25Breakpoints),
            calcularICA(pm10, pm10Breakpoints),
            calcularICA(ozone, ozoneBreakpoints),
            calcularICA(nitrogenDioxide, nitrogenDioxideBreakpoints),
            calcularICA(sulphurDioxide, sulphurDioxideBreakpoints),
            calcularICA(
              carbonMonoxide / 1000,
              carbonMonoxideBreakpoints,
            ), // hay que convertir µg/m³ a mg/m³
          ];
          final icaFinal = icas.whereType<int>().fold(
            0,
            (a, b) => a > b ? a : b,
          );

          dataToUse = {
            "icas": icas,
            "icaFinal": icaFinal,
            "timeStamp": DateTime.now().millisecondsSinceEpoch,
          };

          //Guardar caché
          final success = await prefs.setString(
            cacheKey,
            json.encode(dataToUse),
          );
          debugPrint("¿Guardado ICA en caché?: $success");
        }
      } catch (e) {
        debugPrint("Ha ocurrido un error al calcular la ICA: $e");
      }
    }

    icaCache = dataToUse;
    notifyListeners();
  }
}

class Breakpoint {
  final double clo;
  final double chi;
  final int ilo;
  final int ihi;

  Breakpoint(this.clo, this.chi, this.ilo, this.ihi);
}
